---
name: sync-knowledge
description: Download a local copy of a Delphina workspace's knowledge base — its curated metrics, tables, notes, and rules — so you can grep and read it directly instead of asking Delphina one question at a time. Use when the user asks about their metrics, table semantics, or business definitions; when you need to know how a metric is defined before writing a query; or when they ask to sync, refresh, or pull the knowledge base.
---

# Sync a Delphina knowledge base

Pull a workspace's knowledge base to disk so you can read and grep it locally.

## When this is worth doing

Do it once at the start of a session where the user's questions depend on their
data model — metric definitions, table semantics, business rules. After that the
knowledge base is just files, and normal Read/Grep answer follow-ups with no
further round-trips.

Do not sync before every question. The knowledge base changes on the order of
days, not minutes.

## Steps

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
- Otherwise, install the snapshot:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/apply-snapshot.sh" \
  --url '<archive_url>' \
  --workspace '<workspace_id>' \
  --snapshot '<snapshot_id>'
```

Quote `archive_url` — presigned URLs contain `&` and will otherwise be split by
the shell. The URL expires about 15 minutes after it is issued; if it has gone
stale, call `sync_knowledge` again rather than retrying the download.

If the script reports that the snapshot's layout version is not supported, the
plugin is older than the Delphina deployment. Relay the update commands it
prints; do not try to extract the archive by hand, because the paths will not be
where this skill says they are. A failed install leaves any previous snapshot
untouched, so the existing cache is still usable in the meantime.

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
act on, or a definition they say was changed recently — re-run this skill with
the cached snapshot id instead of trusting the copy on disk.
