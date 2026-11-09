---
name: sync-knowledge
description: Look up a Delphina workspace's knowledge base — its curated metrics, tables, notes, and rules — by searching it one question at a time, or by downloading a local copy to grep and read directly. Use when the user asks about their metrics, table semantics, or business definitions; when you need to know how a metric is defined before writing a query; or when they ask to sync, refresh, or pull the knowledge base.
---

# Read a Delphina knowledge base

There are two ways to read a workspace's knowledge base: search it and read
single documents through Delphina's tools, or download all of it and read and
grep it locally.

## Search, or sync

**Search** for a one-off lookup: one metric's definition, which table holds a
column, a business rule the user named. Call `search_knowledge` with the term,
then `read_knowledge_document` with the `path` of the result you want. To see
what one namespace holds, call `list_knowledge_documents` with `namespace`.
Nothing is downloaded and nothing is written to disk.

**Sync** when the session depends on the data model throughout, for example
when the user is working through several definitions or writing queries that
need many tables' semantics, and whenever they ask to sync, refresh, or pull the
knowledge base. Do it once, at the start of the session. After that the
knowledge base is just files, and normal Read/Grep answer follow-ups with no
further round-trips. If an earlier session left a copy under
`.delphina/knowledge/`, sync again rather than searching: a sync transfers
nothing when the copy is current, and then you can grep it.

Sync even for a one-off lookup when search cannot answer it:

- `search_knowledge` is not among your tools, or it says knowledge search is
  not available for this workspace. Some deployments and workspaces have no
  search index.
- Search finds nothing for a term you expected. Try other words first, such as a
  synonym or the table's name. Before telling the user a definition does not
  exist, call `list_knowledge_documents`: an `indexed_sha` of null means the
  workspace has not been indexed yet, so empty results prove nothing.
- `read_knowledge_document` says a document is too large or is not text.

Search answers at the version its index holds, which can trail a change made in
the last few minutes. A sync always returns the newest version.

Do not sync before every question. The knowledge base changes on the order of
days, not minutes.

## Syncing

**1. Decide which workspace.**

A workspace is one team's warehouse and knowledge base. If the user named one,
use it. Otherwise you can omit it and `sync_knowledge` uses their default.

Call `list_workspaces` when you need to choose and cannot tell — it returns each
workspace's id, name, your role, and which one is the default. If several could
plausibly match what the user meant, ask rather than guessing: syncing the wrong
workspace caches another team's definitions and every later answer is drawn from
them.

**2. Find the cached snapshot id, if any.**

```bash
cat .delphina/knowledge/<workspace-id>/.snapshot-id 2>/dev/null
```

To see what is already cached:

```bash
ls .delphina/knowledge/ 2>/dev/null
```

**3. Call `sync_knowledge`.**

Pass the workspace if you have one — omit it to use the default — and, if step 2
found a cached id, that value as `known_snapshot`. Passing it is what makes a
repeat sync free.

Send `snapshot_id`, not `commit_sha`. The same knowledge base renders
differently depending on `include_evals`, so a bare commit would report a cache
built with different options as current.

**4. Act on the response.**

The response echoes `workspace_id`, so use that for the cache path rather than
whatever selector you passed — a name resolves to an id, and the cache is keyed
by id.

- `unchanged: true` — the local copy is current. Stop here; do not re-download.
- `commit_sha: null` — this workspace has no knowledge base yet. Tell the user
  rather than reporting a successful sync of nothing.
- Otherwise, install the snapshot with the block below.

**5. Install the snapshot.**

Run this block as one Bash command, from the user's project directory. Change
only the three quoted values on its first lines, setting each to the value
`sync_knowledge` returned, and run the rest exactly as written: each line guards
against a way a cache can end up silently wrong.

<!-- install-snapshot:begin -->
```bash
(
  set -euo pipefail
  url='<archive_url>'
  workspace='<workspace_id>'
  snapshot='<snapshot_id>'
  root=.delphina/knowledge
  supported_layouts=' 1 '

  # The workspace id becomes a path segment, so it must not climb out of root.
  case "$workspace" in
    '' | *..* | */* | *\\*) echo "refusing unsafe workspace id: $workspace" >&2; exit 1 ;;
  esac
  command -v unzip >/dev/null || { echo "unzip is required but not installed" >&2; exit 1; }

  # The cache is rebuilt from the server and must never be committed.
  mkdir -p "$root"
  printf '*\n' > "$root/.gitignore"

  # Stage beside the cache and swap only once everything has succeeded, so a
  # failure leaves the previous snapshot exactly as it was.
  staging="$(mktemp -d "$root/.staging.XXXXXX")"
  trap 'rm -rf "$staging"' EXIT

  # --fail, so an expired URL is an error rather than an XML body to unpack.
  curl --fail --silent --show-error --location --max-time 300 \
    --output "$staging/snapshot.zip" "$url"
  # unzip refuses ../ and absolute paths with a non-zero exit, which set -e
  # turns into a failed install rather than files written outside the cache.
  unzip -q "$staging/snapshot.zip" -d "$staging/tree"

  # The layout is where this skill says to grep. Refuse one it does not know.
  layout=""
  if [ -f "$staging/tree/sync-info.json" ]; then
    layout="$(tr -d '[:space:]' < "$staging/tree/sync-info.json" \
      | sed -n 's/.*"layout":\([0-9][0-9]*\).*/\1/p')"
  fi
  case "$supported_layouts" in
    *" ${layout:-none} "*) ;;
    *) echo "unsupported snapshot layout: ${layout:-none}" >&2; exit 3 ;;
  esac

  printf '%s\n' "$snapshot" > "$staging/tree/.snapshot-id"
  if [ -d "$root/$workspace" ]; then mv "$root/$workspace" "$staging/previous"; fi
  mv "$staging/tree" "$root/$workspace"

  echo "Installed $(find "$root/$workspace" -type f -name '*.md' | wc -l | tr -d ' ') documents at $root/$workspace"
  tr -d '[:space:]' < "$root/$workspace/sync-info.json" \
    | sed -n 's/.*"omitted":\[\([^]][^]]*\)\].*/OMITTED: \1/p'
)
```
<!-- install-snapshot:end -->

The URL is presigned: keep it in single quotes, because it contains `&`. It
expires about 15 minutes after it is issued. If the download fails because it
has gone stale, call `sync_knowledge` again rather than retrying the download.

A failed install leaves any previous snapshot untouched, so the existing cache
is still usable while you sort it out.

If the output has an `OMITTED:` line, the server could not include those
documents. Tell the user before answering from the cache.

If the install fails with `unsupported snapshot layout`, this plugin is older
than the user's Delphina deployment. Tell them to update the Delphina plugin
(from `/plugin` in Claude Code). Do not extract the archive another way: the
documents would not be where this skill says to look for them.

## Reading what you get

Documents land at `.delphina/knowledge/<workspace-id>/` as markdown, laid out as
`<namespace>/<type>/<name>.md`, where type is `metric`, `table`, `note`, or
`rule`.

Grep it like any other tree. To find how a metric is defined:

```bash
grep -ril 'revenue' .delphina/knowledge/<workspace-id>/*/metric/
```

`sync-info.json` records the snapshot id, the commit, and the document count,
plus two fields worth checking:

- **`omitted`** — document-shaped paths the server could not include. If this is
  non-empty, say so before answering from the cache: a missing file is
  indistinguishable from "no such metric exists", so silence here turns an
  incomplete knowledge base into a confidently wrong answer.
- **`renamed`** — documents whose filenames collided and were given a `~<hash>`
  suffix. Maps each entry back to the documents behind it.

## What this cache is and isn't

It is a read-only snapshot at a commit. Editing these files changes nothing in
Delphina, and the next sync overwrites them — if the user wants to change a
definition, that is a Delphina KB edit, not a file edit here.

It is also a point-in-time copy. When precision matters — a number the user will
act on, or a definition they say was changed recently — sync again with the
cached snapshot id instead of trusting the copy on disk or a search result.
