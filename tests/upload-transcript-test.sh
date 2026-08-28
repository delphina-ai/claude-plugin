#!/usr/bin/env bash
# Behavioural tests for scripts/upload-transcript.sh.
#
# Two properties here are not "nice to have":
#
#   * The script must ALWAYS exit 0. Claude Code reads exit code 2 from a Stop
#     hook as "do not stop", so a non-zero exit traps the user in a loop caused
#     by telemetry.
#   * A session that never called a Delphina tool must never be uploaded. The
#     filter is the only thing standing between "we collect transcripts of your
#     Delphina work" and "we collect your work".
#
# Uploads go to a local HTTP server so curl's real behaviour — status codes,
# connection failures, timeouts — is exercised rather than stubbed.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../scripts/upload-transcript.sh"
work="$(mktemp -d)"
port="${TEST_PORT:-8795}"
server_pid=""

cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  rm -rf "$work"
  return 0
}
trap cleanup EXIT

failures=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label — expected [$expected], got [$actual]" >&2
    failures=$((failures + 1))
  fi
}

# --- a stub ingestion endpoint ---------------------------------------------
mkdir -p "$work/srv"
cat > "$work/srv/server.py" <<'PY'
import http.server, json, os, sys

STATUS = int(os.environ.get("REPLY_STATUS", "200"))
ACKED = int(os.environ.get("REPLY_ACKED", "0"))
LOG = os.environ["REQ_LOG"]

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        with open(LOG, "a") as fh:
            fh.write(json.dumps({
                "path": self.path,
                "auth": self.headers.get("Authorization", ""),
                "apikey": self.headers.get("x-api-key", ""),
                "body": body.decode("utf-8", "replace"),
            }) + "\n")
        payload = json.dumps({"ackedByteOffset": ACKED, "message": "x"}).encode()
        self.send_response(STATUS)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

start_server() { # status, acked
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  : > "$work/requests.log"
  REPLY_STATUS="$1" REPLY_ACKED="$2" REQ_LOG="$work/requests.log" \
    python3 "$work/srv/server.py" "$port" >/dev/null 2>&1 &
  server_pid=$!
  sleep 0.7
}

# --- fixtures ---------------------------------------------------------------
transcript_with_delphina() {
  cat > "$1" <<'EOF'
{"type":"user","cwd":"/Users/someone/secret-project","message":"hi"}
{"type":"assistant","cwd":"/Users/someone/secret-project","attributionMcpServer":"plugin:delphina:delphina","attributionMcpTool":"sync_knowledge"}
{"type":"assistant","cwd":"/Users/someone/secret-project","message":"done"}
EOF
}

transcript_with_secrets() {
  cat > "$1" <<'EOF'
{"type":"assistant","cwd":"/Users/someone/p","attributionMcpServer":"plugin:delphina:delphina"}
{"type":"user","cwd":"/Users/someone/p","message":"token is dpk_liveSECRETvalue123456 ok"}
{"type":"assistant","cwd":"/Users/someone/p","message":"curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.padding.signature'"}
{"type":"assistant","cwd":"/Users/someone/p","message":"svc dsa_anotherSECRET9876543
EOF
}

transcript_without_delphina() {
  cat > "$1" <<'EOF'
{"type":"user","cwd":"/Users/someone/secret-project","message":"refactor auth"}
{"type":"assistant","cwd":"/Users/someone/secret-project","attributionMcpServer":"linear-server"}
{"type":"assistant","cwd":"/Users/someone/secret-project","attributionPlugin":"delphina","attributionSkill":"delphina:review-branch"}
EOF
}

# A session that never calls a Delphina MCP tool, but greps the knowledge base
# `sync_knowledge` cached to disk. This is the whole point of the sync skill —
# cache once, read it directly afterwards — so these sessions are about the
# knowledge base while carrying no MCP attribution at all.
transcript_reading_kb_cache() {
  cat > "$1" <<'EOF'
{"type":"user","cwd":"/Users/someone/project","message":"how is MAU defined"}
{"type":"assistant","cwd":"/Users/someone/project","message":{"type":"message","content":[{"type":"tool_use","name":"Grep","input":{"pattern":"MAU","path":".delphina/knowledge/ws-abc123/metric/"}}]}}
EOF
}

# The knowledge-base path also turns up in ordinary text, including our own
# spec. Reading a document *about* the cache is not reading anyone's knowledge
# base, and must not make a whole session eligible.
transcript_only_mentioning_kb_cache() {
  cat > "$1" <<'EOF'
{"type":"user","cwd":"/Users/someone/project","message":"where does the cache live"}
{"type":"assistant","cwd":"/Users/someone/project","message":{"type":"message","content":[{"type":"text","text":"It caches to .delphina/knowledge/<workspace-id>/ so you can grep it."}]}}
{"type":"assistant","cwd":"/Users/someone/project","message":{"type":"message","content":[{"type":"tool_use","name":"Read","input":{"file_path":"docs/specs/external-harness-kb.md"}}]}}
EOF
}

# `state` gives each case a clean ~/.delphina.
state() { # enabled, with_credential
  rm -rf "$work/state"
  mkdir -p "$work/state"
  [[ "$1" == "on" ]] && printf '{"enabled": true}\n' > "$work/state/traces.json"
  [[ "$1" == "off" ]] && printf '{"enabled": false}\n' > "$work/state/traces.json"
  [[ "$2" == "cred" ]] && printf 'dpk_test_token\n' > "$work/state/credentials"
  return 0
}

run() { # session_id, transcript
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$1" "$2" |
    DELPHINA_STATE_DIR="$work/state" \
    DELPHINA_API_URL="http://127.0.0.1:$port" \
    "$script" >"$work/out" 2>"$work/err"
  echo $?
}

requests() { wc -l < "$work/requests.log" 2>/dev/null | tr -d ' '; }

start_server 200 999

# --- the exit-0 invariant ---------------------------------------------------
echo "always exits 0, whatever the situation"
T="$work/t.jsonl"; transcript_with_delphina "$T"

state on cred;  check "happy path"          "0" "$(run s1 "$T")"
state off cred; check "capture off"         "0" "$(run s2 "$T")"
state on nocred; check "no credential"      "0" "$(run s3 "$T")"
rm -rf "$work/state"; check "no state at all" "0" "$(run s4 "$T")"
state on cred;  check "transcript missing"  "0" "$(run s5 "$work/nope.jsonl")"
state on cred;  check "empty stdin"         "0" "$(printf '' | DELPHINA_STATE_DIR="$work/state" DELPHINA_API_URL="http://127.0.0.1:$port" "$script" >/dev/null 2>&1; echo $?)"
state on cred;  check "malformed stdin"     "0" "$(printf 'not json' | DELPHINA_STATE_DIR="$work/state" DELPHINA_API_URL="http://127.0.0.1:$port" "$script" >/dev/null 2>&1; echo $?)"

kill "$server_pid" 2>/dev/null; server_pid=""
state on cred;  check "server unreachable"  "0" "$(run s6 "$T")"
start_server 200 999

# --- the filter -------------------------------------------------------------
echo "uploads only sessions that called a Delphina tool"
state on cred
: > "$work/requests.log"
transcript_without_delphina "$work/other.jsonl"
run s7 "$work/other.jsonl" >/dev/null
check "session without a Delphina tool call sends nothing" "0" "$(requests)"

# The decoy above contains attributionPlugin:"delphina" from a repository's own
# .claude/commands/delphina/ skills. Keying on that instead of the MCP server
# would upload whole sessions of unrelated internal work.
check "a delphina-named skill does not count as a tool call" "0" "$(requests)"

: > "$work/requests.log"
run s8 "$T" >/dev/null
check "session with a Delphina tool call is uploaded" "1" "$(requests)"

# --- what actually goes over the wire ---------------------------------------
echo "payload"
# The credential must travel in `x-api-key`. The server's API-key path reads
# only that header (or an `apiKey` query param); `Authorization` is consumed by
# the data-plane service-token path and never evaluated for a user token, so
# sending Bearer is indistinguishable from sending nothing.
#
# The previous version of this check asserted `Bearer dpk_test_token` against a
# stub that echoed whatever it was given, so it passed for the entire time the
# uploader could not authenticate at all. A stub cannot tell you that you are
# speaking the wrong protocol; only the header contract can.
check "credential is sent in x-api-key" "dpk_test_token" \
  "$(python3 -c "import json;print(json.loads(open('$work/requests.log').readline())['apikey'])")"
check "no Authorization header is sent" "" \
  "$(python3 -c "import json;print(json.loads(open('$work/requests.log').readline())['auth'])")"
check "path carries harness and session" "/external-traces/v1/claude-code/sessions/s8/events" \
  "$(python3 -c "import json;print(json.loads(open('$work/requests.log').readline())['path'])")"
check "cwd is stripped before upload" "absent" \
  "$(python3 -c "
import base64, gzip, json
r = json.loads(open('$work/requests.log').readline())
b = json.loads(r['body'])
raw = gzip.decompress(base64.b64decode(b['gzippedDelta'])).decode()
print('present' if 'secret-project' in raw else 'absent')
")"
check "delta starts at offset 0 on a first upload" "0" \
  "$(python3 -c "import json;print(json.loads(json.loads(open('$work/requests.log').readline())['body'])['startOffset'])")"

# --- the cursor -------------------------------------------------------------
echo "cursor"
check "a 200 advances the stored offset" "999" "$(cat "$work/state/offsets/s8" 2>/dev/null)"

start_server 409 4096
state on cred
run s9 "$T" >/dev/null
check "a 409 adopts the server's authoritative offset" "4096" \
  "$(cat "$work/state/offsets/s9" 2>/dev/null)"

start_server 403 0
state on cred
run s10 "$T" >/dev/null
check "a 403 stops this session asking again" "yes" \
  "$([[ -f "$work/state/offsets/s10.disabled" ]] && echo yes || echo no)"
: > "$work/requests.log"
run s10 "$T" >/dev/null
check "and the next turn sends nothing" "0" "$(requests)"

start_server 500 0
state on cred
run s11 "$T" >/dev/null
check "a 5xx leaves the cursor alone so the range is retried" "absent" \
  "$([[ -f "$work/state/offsets/s11" ]] && echo present || echo absent)"

# --- silence ----------------------------------------------------------------
echo "stays quiet"
start_server 200 10
state on cred
run s12 "$T" >/dev/null
check "writes nothing to stdout" "" "$(cat "$work/out")"

# --- knowledge-base reads count as Delphina use -----------------------------
echo "uploads sessions that read a synced knowledge base"
# The gap this closes: `sync_knowledge` caches to disk precisely so later turns
# can grep it directly, and those turns carry no MCP attribution. Without this
# the sessions most about someone's knowledge base were the ones we never saw.
start_server 200 10
state on cred
KBT="$work/kbcache.jsonl"; transcript_reading_kb_cache "$KBT"
run k1 "$KBT" >/dev/null
check "a grep against the cache makes the session eligible" "1" "$(requests)"

# The counterweight. Checked against tool inputs rather than the raw line, so a
# design doc that documents the path does not drag a whole session in with it.
# Truncate rather than delete: `requests` reads the file, and a missing one
# yields empty rather than 0, which would pass this check for the wrong reason.
: > "$work/requests.log"
state on cred
MENT="$work/mention.jsonl"; transcript_only_mentioning_kb_cache "$MENT"
run k2 "$MENT" >/dev/null
check "merely naming the path in prose does not" "0" "$(requests)"

# --- the debug log is opt-in, and safe to turn on ---------------------------
echo "the debug log is opt-in"
# Behavioural rather than structural: an earlier version of this checked that the
# script merely *mentioned* DELPHINA_TRACE_DEBUG, which passed happily with the
# guard removed because the name also appears in two comments.
debug_run() { # session_id, transcript, debug_value ("" to unset)
  local -a env_args=(DELPHINA_STATE_DIR="$work/state" DELPHINA_API_URL="http://127.0.0.1:$port")
  if [[ -n "$3" ]]; then
    env_args+=(DELPHINA_TRACE_DEBUG="$3")
  else
    # Unset rather than merely absent: this has to hold for someone who exported
    # the flag in their own shell, who is exactly the person running this next.
    env_args=(-u DELPHINA_TRACE_DEBUG "${env_args[@]}")
  fi
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$1" "$2" |
    env "${env_args[@]}" "$script" >/dev/null 2>&1
  return 0
}

start_server 200 10
state on cred
debug_run d1 "$T" ""
check "writes no log unless asked" "no" \
  "$([[ -f "$work/state/upload.log" ]] && echo yes || echo no)"

state on cred
debug_run d2 "$T" 1
check "writes a log when asked" "yes" \
  "$([[ -f "$work/state/upload.log" ]] && echo yes || echo no)"
check "records that the upload was accepted" "yes" \
  "$(grep -q '^.*ok: \[d2\] accepted' "$work/state/upload.log" && echo yes || echo no)"

# The log must not become the place a credential lands. The uploader redacts
# them out of uploads precisely because our own setup flow can put one in a
# transcript; a debug file echoing the body would put it back, unredacted.
check "never records the token" "0" \
  "$(grep -c 'dpk_test_token' "$work/state/upload.log" || true)"
check "never records the transcript body" "0" \
  "$(grep -c 'gzippedDelta\|attributionMcpServer' "$work/state/upload.log" || true)"

# The reason nothing was sent is the whole point of the log: an ineligible
# session is the most common cause of "capture looks broken".
state on cred
NOD="$work/nodelphina.jsonl"; transcript_without_delphina "$NOD"
debug_run d3 "$NOD" 1
check "explains an ineligible session" "yes" \
  "$(grep -q 'nor read a synced knowledge base' "$work/state/upload.log" && echo yes || echo no)"

# --- credentials never leave the machine -----------------------------------
echo "redacts credentials before upload"
start_server 200 10
state on cred
transcript_with_secrets "$work/secrets.jsonl"
: > "$work/requests.log"
run s14 "$work/secrets.jsonl" >/dev/null

uploaded="$(python3 -c "
import base64, gzip, json
r = json.loads(open('$work/requests.log').readline())
b = json.loads(r['body'])
print(gzip.decompress(base64.b64decode(b['gzippedDelta'])).decode())
")"

check "a personal token is gone" "absent" \
  "$(grep -q 'liveSECRETvalue' <<<"$uploaded" && echo present || echo absent)"
check "a bearer value is gone" "absent" \
  "$(grep -q 'padding.signature' <<<"$uploaded" && echo present || echo absent)"
# The last line is deliberately truncated mid-JSON, the shape a transcript takes
# when it is flushed asynchronously. Those lines are kept verbatim so nothing is
# dropped, which is exactly why redaction runs over the finished payload rather
# than over parsed fields.
check "a token on an unparseable line is gone" "absent" \
  "$(grep -q 'anotherSECRET' <<<"$uploaded" && echo present || echo absent)"
check "the prefix survives so a reader can tell what was removed" "present" \
  "$(grep -q 'dpk_\[redacted\]' <<<"$uploaded" && echo present || echo absent)"
check "ordinary content is untouched" "present" \
  "$(grep -q 'attributionMcpServer' <<<"$uploaded" && echo present || echo absent)"

# --- a cursor that outran the file -----------------------------------------
echo "a stored offset past the end of the transcript"
start_server 200 10
state on cred
mkdir -p "$work/state/offsets"
echo 999999 > "$work/state/offsets/s13"
: > "$work/requests.log"
check "exits 0" "0" "$(run s13 "$T")"
check "sends nothing rather than a nonsensical range" "0" "$(requests)"
check "leaves the stored offset alone" "999999" "$(cat "$work/state/offsets/s13")"
# Documented, not incidental. Transcripts are append-only within a session, so
# this should be unreachable — but if a transcript were ever replaced by a
# shorter file at the same path, uploads for that session would stop silently
# and permanently. Resetting to zero instead would oscillate: the server would
# answer 409 with its own larger offset, which is past the file again. Neither
# is good, and the quiet option is the safer one, so it is pinned here rather
# than left to be rediscovered.

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
