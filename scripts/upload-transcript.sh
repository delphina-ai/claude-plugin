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

# Reported to the server as `clientVersion`, which exists to identify a bad
# client in the field. It has to match the manifest to be worth anything, and it
# silently did not from 0.1.0 through 0.3.0 — every upload claimed 0.1.0.
# `tests/plugin-contract-test.sh` now fails when the two disagree.
VERSION="0.5.3"
STATE_DIR="${DELPHINA_STATE_DIR:-$HOME/.delphina}"
CONFIG="$STATE_DIR/traces.json"
CRED="$STATE_DIR/credentials"
DEBUG_LOG="$STATE_DIR/upload.log"
API_BASE="${DELPHINA_API_URL:-https://app.delphina.ai/api}"
HARNESS="claude-code"

# --- Optional debug log -----------------------------------------------------
# Off unless DELPHINA_TRACE_DEBUG=1.
#
# Every failure path here is a silent `exit 0`, which is right for a hook — its
# stdout is shown to the user, and a non-zero Stop exit traps them — but it
# leaves "did my trace upload?" with no answer, including for us. This writes
# outcomes to a file, where no turn is interrupted by them.
#
# Statuses, byte counts, and skip reasons only. The request body is never
# logged: it is the user's transcript, and the redaction pass below exists to
# keep credentials out of what we persist. A debug log echoing the body would
# put both back on disk, unredacted, in a file nobody remembers enabling.
#
# The subshell matters. `trap ... ERR` above fires on any non-zero command, and
# an ERR trap is not inherited by a subshell unless `set -E` is on, so this
# cannot make logging turn an upload into an early `exit 0`.
dlog() {
  [[ "${DELPHINA_TRACE_DEBUG:-}" == 1 ]] || return 0
  (
    mkdir -p "$STATE_DIR" 2>/dev/null
    # Truncate rather than rotate: this is a debugging aid, the recent lines are
    # the ones anyone reads, and a machine left with the flag on should not fill
    # its disk.
    if [[ -f "$DEBUG_LOG" ]] && [[ "$(wc -c < "$DEBUG_LOG" 2>/dev/null || echo 0)" -gt 262144 ]]; then
      : > "$DEBUG_LOG" 2>/dev/null
    fi
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$DEBUG_LOG" 2>/dev/null
  ) || true
  return 0
}

# --- Gate 1: is trace capture switched on at all? --------------------------
# First, and deliberately before the transcript is read. When capture is off this
# process opens nothing belonging to the user: not their code, not the output of
# their other tools. "We do not upload" and "we do not read" are different
# promises, and only the second is worth making.
if [[ ! -f "$CONFIG" ]]; then
  dlog "stop: trace capture not configured on this machine ($CONFIG absent)"
  exit 0
fi
if ! grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$CONFIG" 2>/dev/null; then
  dlog "stop: trace capture switched off locally ($CONFIG has enabled != true)"
  exit 0
fi

# --- Gate 2: do we have a credential? --------------------------------------
if [[ ! -r "$CRED" ]]; then
  dlog "stop: no credential at $CRED — run /delphina:setup"
  exit 0
fi
TOKEN="$(tr -d '[:space:]' < "$CRED")"
if [[ -z "$TOKEN" ]]; then
  dlog "stop: credential file is empty — run /delphina:setup"
  exit 0
fi

# The hook payload arrives as JSON on stdin.
PAYLOAD="$(cat)"
[[ -n "$PAYLOAD" ]] || exit 0

if ! command -v python3 >/dev/null 2>&1; then
  dlog "stop: python3 not on PATH"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  dlog "stop: curl not on PATH"
  exit 0
fi

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

if [[ -z "${SESSION_ID:-}" || -z "${TRANSCRIPT:-}" ]]; then
  dlog "stop: hook payload had no usable session_id/transcript_path"
  exit 0
fi
if [[ ! -r "$TRANSCRIPT" ]]; then
  dlog "stop: [$SESSION_ID] transcript not readable at $TRANSCRIPT"
  exit 0
fi

OFFSET_FILE="$STATE_DIR/offsets/$SESSION_ID"
mkdir -p "$STATE_DIR/offsets" 2>/dev/null || exit 0

# A 403 means the organization has capture switched off. Stop asking rather than
# retrying every turn for the rest of the session.
if [[ -f "$OFFSET_FILE.disabled" ]]; then
  dlog "stop: [$SESSION_ID] organization has capture disabled (sticky 403 this session)"
  exit 0
fi

START="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
[[ "$START" =~ ^[0-9]+$ ]] || START=0

# --- Gate 3 and the payload, in one pass ------------------------------------
# Whether this session ever called a Delphina MCP tool decides if ANY of it is
# eligible, and the answer needs the whole file, not just the new part — the
# call may have happened many turns ago.
# "Nothing was uploaded" is usually the payload step deciding this session is
# ineligible, which is by far the most common reason someone thinks capture is
# broken. Keep its stderr when debugging so the reason reaches the log; discard
# it otherwise, exactly as before.
PY_ERR=/dev/null
if [[ "${DELPHINA_TRACE_DEBUG:-}" == 1 ]]; then
  PY_ERR="$(mktemp "${TMPDIR:-/tmp}/delphina-upload.XXXXXX" 2>/dev/null || echo /dev/null)"
fi

BODY="$(
  DELPHINA_START="$START" DELPHINA_VERSION="$VERSION" python3 - "$TRANSCRIPT" <<'PY' 2>"$PY_ERR"
import base64, gzip, io, json, os, re, sys

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

# The knowledge base is also read straight off disk. `sync_knowledge` caches a
# workspace to `.delphina/knowledge/<workspace-id>/` for exactly that purpose —
# so later turns can grep it instead of asking Delphina one question at a time.
# Those turns carry no MCP attribution at all, so a session can be entirely
# about someone's knowledge base and look, to the check above, untouched.
#
# A trailing path segment is required so that `.delphina/knowledge` on its own
# does not match. The bare string appears in prose, including our own spec.
_KB_CACHE_PATH = re.compile(r"\.delphina/knowledge/[^\s\"']+")


def reads_kb_cache(entry):
    """Whether an entry runs a tool against a synced knowledge-base cache.

    Checked against tool *inputs* rather than the raw line. The path turns up in
    ordinary text too — a design doc that documents it, a message discussing it
    — and reading a document about the knowledge base is not using one. Only a
    tool actually pointed at the cache counts.

    Covers every tool that takes a path without naming any of them: Read's
    `file_path`, Grep's `path`, Bash's `command`, Glob's `pattern`. A tool added
    later gets the same treatment for free, which matters because the failure
    mode of enumerating them is a silent gap rather than an error.
    """
    message = entry.get("message")
    if not isinstance(message, dict):
        return False
    content = message.get("content")
    if not isinstance(content, list):
        return False
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        try:
            serialized = json.dumps(block.get("input"))
        except (TypeError, ValueError):
            continue
        if _KB_CACHE_PATH.search(serialized):
            return True
    return False

# Delphina credential shapes. Applied to the finished payload rather than to
# parsed fields, so a half-written line kept verbatim above is covered too.
#
# This is NOT general secret scanning, and should not be described as such: it
# removes credentials whose shape we define, because our own setup flow can put
# one in a transcript — the model reads the token to write it to disk, and the
# transcript of that session is exactly what gets uploaded next. A `Bearer`
# value is included because shell output echoing an Authorization header is the
# other way one turns up.
_SECRET_PATTERNS = [
    re.compile(rb"\b(dpk_|dsa_)[A-Za-z0-9_-]{8,}"),
    re.compile(rb"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{16,}"),
]


def redact_credentials(blob):
    """Replace credential-shaped runs with a marker.

    Keeps the prefix so a reader can tell what was removed, which matters when
    someone is trying to work out why a trace looks odd.
    """
    for pattern in _SECRET_PATTERNS:
        blob = pattern.sub(rb"\1[redacted]", blob)
    return blob


def skip(reason):
    """Report why nothing is being uploaded, for the optional debug log.

    stderr is discarded unless DELPHINA_TRACE_DEBUG=1, so this is free in normal
    operation and never reaches the user's turn either way.
    """
    sys.stderr.write(reason + "\n")
    sys.exit(0)


used_delphina = False
try:
    size = os.path.getsize(path)
except OSError:
    skip("transcript disappeared while reading it")

if size <= start:
    skip(f"no new bytes (offset {start}, transcript {size})")

# Pass one: eligibility, over the whole transcript.
with open(path, "rb") as fh:
    for raw in fh:
        if b"delphina" not in raw.lower():
            continue
        try:
            entry = json.loads(raw)
        except Exception:
            continue
        if is_delphina_server(entry.get("attributionMcpServer")) or reads_kb_cache(entry):
            used_delphina = True
            break

if not used_delphina:
    skip("session neither called a Delphina tool nor read a synced knowledge base")

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

payload = redact_credentials(b"\n".join(lines) + b"\n")
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

if [[ "$PY_ERR" != /dev/null ]]; then
  PY_REASON="$(cat "$PY_ERR" 2>/dev/null || true)"
  rm -f "$PY_ERR" 2>/dev/null || true
  if [[ -n "$PY_REASON" ]]; then
    dlog "stop: [$SESSION_ID] $PY_REASON"
  fi
fi

if [[ -z "$BODY" ]]; then
  exit 0
fi

dlog "post: [$SESSION_ID] uploading from offset $START"

URL="$API_BASE/external-traces/v1/$HARNESS/sessions/$SESSION_ID/events"
# `x-api-key`, not `Authorization: Bearer`. The API-key path reads only this
# header (or an `apiKey` query param); `Authorization` is consumed by the
# data-plane service-token path, which is gated to a different set of endpoints
# and expects a service JWT rather than a user token. Sending Bearer here is
# byte-identical to sending no credential at all — the server answers "No
# authentication!" and the token is never evaluated, which is what happened for
# the whole 0.2.0–0.4.0 line.
RESPONSE="$(
  printf '%s' "$BODY" | curl --silent --show-error --max-time 30 \
    --write-out '\n%{http_code}' \
    --header "x-api-key: $TOKEN" \
    --header 'Content-Type: application/json' \
    --data @- \
    "$URL" 2>/dev/null
)" || {
  dlog "retry: [$SESSION_ID] curl could not complete the request, resending next turn"
  exit 0
}

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
    dlog "ok: [$SESSION_ID] accepted, server offset now $(cat "$OFFSET_FILE" 2>/dev/null || echo unknown)"
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
    dlog "resync: [$SESSION_ID] 409, adopted server offset $(cat "$OFFSET_FILE" 2>/dev/null || echo unknown)"
    ;;
  401)
    # The credential is not valid — revoked, deleted, or replaced by a setup run
    # on another machine. Permanent, exactly like a 403, and retrying it every
    # turn for the life of the session re-reads and re-gzips the whole
    # transcript to make a request that cannot succeed. It is also silent
    # without DELPHINA_TRACE_DEBUG, which is how a machine can sit uploading
    # nothing for days while looking healthy.
    #
    # Marked per session like the 403 rather than globally: a session already
    # underway stops asking, and the next `/delphina:setup` writes a working
    # credential that new sessions pick up without anything to clear.
    : > "$OFFSET_FILE.disabled" 2>/dev/null || true
    dlog "denied: [$SESSION_ID] 401, credential rejected — re-run /delphina:setup"
    ;;
  403)
    # The organization has not enabled capture. Stop asking for this session.
    : > "$OFFSET_FILE.disabled" 2>/dev/null || true
    dlog "denied: [$SESSION_ID] 403, organization has not enabled trace capture"
    ;;
  *)
    # Anything else — network, 5xx, a payload the server rejected — is retried on
    # the next turn from the same offset. Nothing is logged to stdout: a hook's
    # output is surfaced to the user, and telemetry has no business interrupting.
    # An empty status is curl failing to reach us at all.
    dlog "retry: [$SESSION_ID] HTTP ${STATUS:-none}, will resend from offset $START next turn"
    ;;
esac

exit 0
