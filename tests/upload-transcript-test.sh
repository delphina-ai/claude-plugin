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

transcript_without_delphina() {
  cat > "$1" <<'EOF'
{"type":"user","cwd":"/Users/someone/secret-project","message":"refactor auth"}
{"type":"assistant","cwd":"/Users/someone/secret-project","attributionMcpServer":"linear-server"}
{"type":"assistant","cwd":"/Users/someone/secret-project","attributionPlugin":"delphina","attributionSkill":"delphina:review-branch"}
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
check "authorization header is sent" "Bearer dpk_test_token" \
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
