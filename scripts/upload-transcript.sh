#!/usr/bin/env bash
# Upload the new part of this session's transcript to Delphina.
#
# Runs from the Stop and SessionEnd hooks, which fire on EVERY turn of EVERY
# session while the plugin is enabled — including sessions that have nothing to
# do with Delphina. The gates below run cheapest-first for that reason, and the
# kill switch is checked before the transcript is opened at all.
#
# THIS SCRIPT MUST ALWAYS EXIT 0.
#
# A non-zero exit from a Stop hook does not just log an error: Claude Code reads
# exit code 2 as "do not stop", which traps the user in a loop they cannot easily
# escape, caused by telemetry. Every failure path here is therefore a silent
# `exit 0` and a retry on the next turn. Uploads are at-least-once by design and
# the server is idempotent, so dropping one costs nothing.
set -uo pipefail

# Never let a failure escape, whatever goes wrong below.
trap 'exit 0' ERR

VERSION="0.1.0"
STATE_DIR="${DELPHINA_STATE_DIR:-$HOME/.delphina}"
CONFIG="$STATE_DIR/traces.json"
CRED="$STATE_DIR/credentials"
API_BASE="${DELPHINA_API_URL:-https://app.delphina.ai/api}"
HARNESS="claude-code"

# --- Gate 1: is trace capture switched on at all? --------------------------
# First, and deliberately before the transcript is read. When capture is off this
# process opens nothing belonging to the user: not their code, not the output of
# their other tools. "We do not upload" and "we do not read" are different
# promises, and only the second is worth making.
[[ -f "$CONFIG" ]] || exit 0
grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$CONFIG" 2>/dev/null || exit 0

# --- Gate 2: do we have a credential? --------------------------------------
[[ -r "$CRED" ]] || exit 0
TOKEN="$(tr -d '[:space:]' < "$CRED")"
[[ -n "$TOKEN" ]] || exit 0

# The hook payload arrives as JSON on stdin.
PAYLOAD="$(cat)"
[[ -n "$PAYLOAD" ]] || exit 0

command -v python3 >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

read -r SESSION_ID TRANSCRIPT <<<"$(
  printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    o = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sid = str(o.get("session_id") or "")
path = str(o.get("transcript_path") or "")
# A session id becomes a filename below and reaches a URL path segment. It comes
# from the harness rather than a user, but it is still checked here.
if not sid or not path or "/" in sid or ".." in sid:
    sys.exit(0)
print(sid, path)
' 2>/dev/null)" || exit 0

[[ -n "${SESSION_ID:-}" && -n "${TRANSCRIPT:-}" ]] || exit 0
[[ -r "$TRANSCRIPT" ]] || exit 0

OFFSET_FILE="$STATE_DIR/offsets/$SESSION_ID"
mkdir -p "$STATE_DIR/offsets" 2>/dev/null || exit 0

# A 403 means the organization has capture switched off. Stop asking rather than
# retrying every turn for the rest of the session.
[[ -f "$OFFSET_FILE.disabled" ]] && exit 0

START="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
[[ "$START" =~ ^[0-9]+$ ]] || START=0

# --- Gate 3 and the payload, in one pass ------------------------------------
# Whether this session ever called a Delphina MCP tool decides if ANY of it is
# eligible, and the answer needs the whole file, not just the new part — the
# call may have happened many turns ago.
BODY="$(
  DELPHINA_START="$START" DELPHINA_VERSION="$VERSION" python3 - "$TRANSCRIPT" <<'PY' 2>/dev/null
import base64, gzip, io, json, os, sys

path = sys.argv[1]
start = int(os.environ["DELPHINA_START"])

def is_delphina_server(value):
    """Whether an MCP attribution names our server.

    Two spellings reach here. A hand-configured server (`claude mcp add
    delphina ...`) attributes as `delphina`; one bundled in a plugin is
    namespaced, e.g. `plugin:delphina:delphina`. Comparing the last
    colon-separated component covers both without matching a server that merely
    contains the word.

    Deliberately NOT keyed on `attributionPlugin`, which names the plugin or
    skill namespace rather than an MCP call: a repository with its own
    `.claude/commands/delphina/` skills produces `attributionPlugin: "delphina"`
    for internal dev workflows that never touch Delphina at all. Filtering on
    that would upload whole sessions on the strength of a name collision.
    """
    return isinstance(value, str) and value.rsplit(":", 1)[-1] == "delphina"

used_delphina = False
try:
    size = os.path.getsize(path)
except OSError:
    sys.exit(0)

if size <= start:
    sys.exit(0)

# Pass one: eligibility, over the whole transcript.
with open(path, "rb") as fh:
    for raw in fh:
        if b"delphina" not in raw.lower():
            continue
        try:
            entry = json.loads(raw)
        except Exception:
            continue
        if is_delphina_server(entry.get("attributionMcpServer")):
            used_delphina = True
            break

if not used_delphina:
    sys.exit(0)

# Pass two: the new bytes only, with `cwd` stripped.
#
# `cwd` is stamped on every entry and leaks a filesystem path — project names,
# usernames, client names. Removing it changes the payload relative to the file,
# which is fine: offsets describe the file, and the object the server stores is
# named by that range. A retry re-derives identical bytes from identical input.
out = io.BytesIO()
with open(path, "rb") as fh:
    fh.seek(start)
    chunk = fh.read(size - start)

lines = []
for raw in chunk.split(b"\n"):
    if not raw.strip():
        continue
    try:
        entry = json.loads(raw)
    except Exception:
        # An entry we cannot parse is very likely a half-written final line —
        # the transcript is flushed asynchronously. Keep it verbatim so nothing
        # is silently dropped; the server stores raw text either way.
        lines.append(raw)
        continue
    entry.pop("cwd", None)
    lines.append(json.dumps(entry, separators=(",", ":")).encode("utf-8"))

payload = b"\n".join(lines) + b"\n"
with gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as gz:
    gz.write(payload)

print(
    json.dumps(
        {
            "startOffset": start,
            "endOffset": size,
            "gzippedDelta": base64.b64encode(out.getvalue()).decode("ascii"),
            "clientVersion": os.environ["DELPHINA_VERSION"],
        }
    )
)
PY
)" || exit 0

[[ -n "$BODY" ]] || exit 0

URL="$API_BASE/external-traces/v1/$HARNESS/sessions/$SESSION_ID/events"
RESPONSE="$(
  printf '%s' "$BODY" | curl --silent --show-error --max-time 30 \
    --write-out '\n%{http_code}' \
    --header "Authorization: Bearer $TOKEN" \
    --header 'Content-Type: application/json' \
    --data @- \
    "$URL" 2>/dev/null
)" || exit 0

STATUS="$(printf '%s' "$RESPONSE" | tail -n 1)"
BODY_OUT="$(printf '%s' "$RESPONSE" | sed '$d')"

case "$STATUS" in
  200)
    printf '%s' "$BODY_OUT" | python3 -c '
import json, sys
try:
    print(int(json.load(sys.stdin)["ackedByteOffset"]))
except Exception:
    sys.exit(1)
' > "$OFFSET_FILE.tmp" 2>/dev/null && mv "$OFFSET_FILE.tmp" "$OFFSET_FILE"
    ;;
  409)
    # We drifted from the server's cursor. It returns the authoritative offset;
    # adopt it so the next turn resumes from the right place instead of retrying
    # a range that will be refused forever.
    printf '%s' "$BODY_OUT" | python3 -c '
import json, sys
try:
    print(int(json.load(sys.stdin)["ackedByteOffset"]))
except Exception:
    sys.exit(1)
' > "$OFFSET_FILE.tmp" 2>/dev/null && mv "$OFFSET_FILE.tmp" "$OFFSET_FILE"
    ;;
  403)
    # The organization has not enabled capture. Stop asking for this session.
    : > "$OFFSET_FILE.disabled" 2>/dev/null || true
    ;;
  *)
    # Anything else — network, 5xx, a payload the server rejected — is retried on
    # the next turn from the same offset. Nothing is logged to stdout: a hook's
    # output is surfaced to the user, and telemetry has no business interrupting.
    ;;
esac

exit 0
