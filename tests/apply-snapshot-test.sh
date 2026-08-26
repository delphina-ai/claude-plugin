#!/usr/bin/env bash
# Behavioural tests for scripts/apply-snapshot.sh.
#
# The install script is the one piece of this plugin that can silently corrupt a
# user's knowledge base — a partial extraction, a stale cache left behind by a
# failed download, or a tree written outside the cache root. Each of those is
# invisible to the model consuming the result, so they are pinned here rather
# than left to manual checking.
#
# Fixtures are served over a real local HTTP server so curl's failure paths
# (404, connection refused) run for real rather than being stubbed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../scripts/apply-snapshot.sh"
work="$(mktemp -d)"
port="${TEST_PORT:-8791}"
server_pid=""

cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
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

# --- fixtures --------------------------------------------------------------
mkdir -p "$work/serve"

make_zip() { # name, sync-info-json, doc-paths...
  local name="$1" info="$2"; shift 2
  local build="$work/build-$name"
  rm -rf "$build"
  for path in "$@"; do
    mkdir -p "$build/$(dirname "$path")"
    echo "# content of $path" > "$build/$path"
  done
  [[ -n "$info" ]] && printf '%s' "$info" > "$build/sync-info.json"
  (cd "$build" && zip -qr "$work/serve/$name.zip" .)
}

make_zip good \
  '{"layout": 1, "snapshot_id": "abc_public_v1", "document_count": 2, "omitted": [], "renamed": {}}' \
  analytics/metric/revenue.md sales/table/orders.md

make_zip shrunk \
  '{"layout": 1, "snapshot_id": "def_public_v1", "document_count": 1, "omitted": [], "renamed": {}}' \
  analytics/metric/revenue.md

make_zip future \
  '{"layout": 99, "snapshot_id": "ghi_public_v99", "document_count": 1, "omitted": []}' \
  analytics/metric/revenue.md

make_zip nolayout \
  '{"snapshot_id": "jkl", "document_count": 1}' \
  analytics/metric/revenue.md

# Pretty-printed across lines, exactly as the server's json.dumps(indent=2)
# writes it — the parser must not assume single-line JSON.
make_zip omitting \
  '{
  "layout": 1,
  "snapshot_id": "mno_public_v1",
  "document_count": 1,
  "renamed": {},
  "omitted": [
    "analytics/dbt-model/orders"
  ]
}' \
  analytics/metric/revenue.md

python3 -m http.server "$port" --directory "$work/serve" >/dev/null 2>&1 &
server_pid=$!
sleep 1

root="$work/.delphina/knowledge"
run() { "$script" --root "$root" "$@" >"$work/out" 2>"$work/err"; }

# --- a first sync installs the tree ----------------------------------------
echo "installs a snapshot"
run --url "http://127.0.0.1:$port/good.zip" --workspace ws-1 --snapshot "abc_public_v1" && rc=0 || rc=$?
check "exits 0" "0" "$rc"
check "stores the snapshot id" "abc_public_v1" "$(cat "$root/ws-1/.snapshot-id" 2>/dev/null || echo MISSING)"
check "extracts documents" "# content of analytics/metric/revenue.md" \
  "$(cat "$root/ws-1/analytics/metric/revenue.md" 2>/dev/null || echo MISSING)"
check "git-ignores the cache" "*" "$(cat "$root/.gitignore" 2>/dev/null || echo MISSING)"
check "leaves no staging dirs" "" "$(find "$root" -maxdepth 1 -name '.staging.*' -o -maxdepth 1 -name '.previous.*' | tr -d '\n')"

# --- a failed download must not destroy a good cache -----------------------
echo "a failed download leaves the previous cache intact"
run --url "http://127.0.0.1:$port/gone.zip" --workspace ws-1 --snapshot "zzz" && rc=0 || rc=$?
check "exits non-zero" "22" "$rc"
check "keeps the old snapshot id" "abc_public_v1" "$(cat "$root/ws-1/.snapshot-id")"
check "keeps the old documents" "# content of sales/table/orders.md" \
  "$(cat "$root/ws-1/sales/table/orders.md")"

# --- an unknown layout is refused, cache untouched --------------------------
echo "refuses a layout it cannot read"
run --url "http://127.0.0.1:$port/future.zip" --workspace ws-1 --snapshot "ghi_public_v99" && rc=0 || rc=$?
check "exits non-zero" "1" "$rc"
check "names the update command" "yes" \
  "$(grep -q 'claude plugin update' "$work/err" && echo yes || echo no)"
check "keeps the old cache" "abc_public_v1" "$(cat "$root/ws-1/.snapshot-id")"

echo "refuses a snapshot with no layout at all"
run --url "http://127.0.0.1:$port/nolayout.zip" --workspace ws-1 --snapshot "jkl" && rc=0 || rc=$?
check "exits non-zero" "1" "$rc"

# --- a workspace id can never escape the cache root ------------------------
echo "refuses an unsafe workspace id"
for bad in "../escape" "a/b" 'a\b'; do
  run --url "http://127.0.0.1:$port/good.zip" --workspace "$bad" --snapshot "abc" && rc=0 || rc=$?
  check "refuses [$bad]" "1" "$rc"
done
check "nothing escaped the root" "" "$(find "$work" -maxdepth 1 -name 'escape*' | tr -d '\n')"

# --- a re-sync fully replaces, so upstream deletions propagate -------------
echo "replaces rather than merges"
run --url "http://127.0.0.1:$port/shrunk.zip" --workspace ws-1 --snapshot "def_public_v1" && rc=0 || rc=$?
check "exits 0" "0" "$rc"
check "new snapshot id" "def_public_v1" "$(cat "$root/ws-1/.snapshot-id")"
check "deleted document is gone" "MISSING" \
  "$(cat "$root/ws-1/sales/table/orders.md" 2>/dev/null || echo MISSING)"

# --- omissions are surfaced, not swallowed ---------------------------------
echo "warns when the server omitted documents"
run --url "http://127.0.0.1:$port/omitting.zip" --workspace ws-2 --snapshot "mno_public_v1" && rc=0 || rc=$?
check "still installs" "0" "$rc"
check "warns about the omission" "yes" \
  "$(grep -q 'analytics/dbt-model/orders' "$work/err" && echo yes || echo no)"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
