#!/usr/bin/env bash
# Structural checks on the plugin itself.
#
# `claude plugin validate` covers manifest shape. What it cannot see is whether
# the pieces still refer to each other correctly: a hook that names a script
# which was renamed, a skill that documents a flag the script stopped accepting,
# a script that lost its executable bit. Each of those fails at run time, on a
# customer's machine, and silently — a hook's failures are swallowed by design.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."

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

# --- hooks point at scripts that exist and can run -------------------------
echo "hooks resolve to runnable scripts"
hook_commands="$(
  python3 - "$root/hooks/hooks.json" <<'PY'
import json, re, sys

with open(sys.argv[1]) as fh:
    doc = json.load(fh)

for handlers in doc.get("hooks", {}).values():
    for group in handlers:
        for hook in group.get("hooks", []):
            command = hook.get("command", "")
            # Strip the ${CLAUDE_PLUGIN_ROOT} prefix and any quoting around it.
            match = re.search(r"/(scripts/[A-Za-z0-9_.-]+)", command)
            if match:
                print(match.group(1))
PY
)"

check "at least one hook is registered" "yes" \
  "$([[ -n "$hook_commands" ]] && echo yes || echo no)"

while read -r rel; do
  [[ -z "$rel" ]] && continue
  check "$rel exists" "yes" "$([[ -f "$root/$rel" ]] && echo yes || echo no)"
  check "$rel is executable" "yes" "$([[ -x "$root/$rel" ]] && echo yes || echo no)"
  # Git tracks the bit, but a contributor on a filesystem that does not can drop
  # it, and a hook whose command is not executable fails on every single turn.
  check "$rel is executable in git" "100755" \
    "$(cd "$root" && git ls-files -s "$rel" 2>/dev/null | awk '{print $1}')"
done <<<"$hook_commands"

# --- every script is executable --------------------------------------------
echo "all shipped scripts are executable"
for f in "$root"/scripts/*.sh; do
  rel="scripts/$(basename "$f")"
  check "$rel is executable" "yes" "$([[ -x "$f" ]] && echo yes || echo no)"
done

# --- skills invoke flags their scripts accept ------------------------------
echo "skills and scripts agree on their interface"
# The sync-knowledge skill tells the model how to call apply-snapshot.sh. A
# rename on either side leaves the other wrong, and the failure surfaces as the
# model running a command that errors mid-task. This has happened once already,
# when --sha became --snapshot.
documented="$(grep -o '\-\-[a-z][a-z-]*' "$root/skills/sync-knowledge/SKILL.md" | sort -u)"
accepted="$(grep -o '^\s*--[a-z][a-z-]*)' "$root/scripts/apply-snapshot.sh" | tr -d ' )' | sort -u)"

while read -r flag; do
  [[ -z "$flag" ]] && continue
  check "apply-snapshot.sh accepts $flag as the skill documents" "yes" \
    "$(grep -qx -- "$flag" <<<"$accepted" && echo yes || echo no)"
done <<<"$documented"

# --- the setup command names the paths the uploader actually uses ----------
echo "setup command matches the uploader's state layout"
for path in ".delphina/traces.json" ".delphina/credentials" ".delphina/offsets"; do
  check "setup mentions $path" "yes" \
    "$(grep -qF "$path" "$root/commands/setup.md" && echo yes || echo no)"
  check "the uploader actually uses $(basename "$path")" "yes" \
    "$(grep -qF "$(basename "$path")" "$root/scripts/upload-transcript.sh" && echo yes || echo no)"
done

# --- setup's credential story stays internally consistent ------------------
echo "setup documents the minted credential end to end"
# The token is minted by an MCP tool and its id recorded locally so the NEXT run
# can retire it. Three places have to agree, and a half-updated doc is the
# realistic failure: it leaves live credentials on the server forever.
check "setup names the minting tool" "yes" \
  "$(grep -qF 'create_trace_upload_token' "$root/commands/setup.md" && echo yes || echo no)"
check "setup passes the recorded id back as replaces_token_id" "yes" \
  "$(grep -qF 'replaces_token_id' "$root/commands/setup.md" && echo yes || echo no)"
# token-id has three distinct roles, and each is checked on its own. A count
# threshold would not do: the file is mentioned four times, so dropping the
# teardown line still cleared any count that also passed before.
check "setup writes the id" "yes" \
  "$(grep -qE 'value into .~/\.delphina/token-id' "$root/commands/setup.md" && echo yes || echo no)"
check "setup reads the id back on a repeat run" "yes" \
  "$(grep -qE 'cat ~/\.delphina/token-id' "$root/commands/setup.md" && echo yes || echo no)"
check "teardown removes the id" "yes" \
  "$(grep -qE '^rm -f .*\.delphina/token-id' "$root/commands/setup.md" && echo yes || echo no)"

# --- the uploader can never fail a turn ------------------------------------
echo "the uploader cannot fail a user's turn"
# Exit code 2 from a Stop hook means "do not stop", which traps the user in a
# loop. The behavioural tests cover the paths that exist today; this catches a
# newly added `exit 1` that no test happens to reach.
# Matches anywhere on the line, not just at its start: the realistic mistake is
# `|| exit 1` appended to a guard, not a bare statement. Comment lines are
# excluded so prose about exit codes does not trip it.
check "no non-zero exit anywhere in the uploader" "0" \
  "$(grep -vE '^\s*#' "$root/scripts/upload-transcript.sh" | grep -cE 'exit [1-9]' || true)"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
