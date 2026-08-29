# Changelog

## 0.5.3

- **Fixes the load error every 0.5.2 install shows on its `/plugin` screen.**
  The manifest ended with `"hooks": "./hooks/hooks.json"`, but Claude Code
  already loads `hooks/hooks.json` by convention; the `hooks` field is for
  *additional* files. So the file was asked for twice and the second request was
  refused — "Duplicate hooks file detected" — which reads like the hooks failed
  to install.

  They did not: the conventional load happens first and succeeds, so Stop and
  SessionEnd have been registered and uploads have run normally the whole time.
  The bug was cosmetic, but it was cosmetic in the one place someone looks to
  confirm the plugin is healthy.

  `claude plugin validate --strict` passes either way, since a redundant field
  is still a well-formed one. A contract test now covers it instead.

## 0.5.2

- Says plainly that **any admin of your organization can read an uploaded
  transcript**, in both the README and what `/delphina:setup` tells you before
  you enable capture. That has become true in the Delphina web app, and it is
  the part someone is most likely to assume works the other way — an uploaded
  session cannot be taken back, so it belongs in front of the decision rather
  than after it.

## 0.5.1

- **Fixes uploads, which have never worked.** The uploader sent its credential
  as `Authorization: Bearer`, but the server's API-key path reads only
  `x-api-key` — `Authorization` belongs to the data-plane service-token path and
  is never evaluated for a user token. Every upload since trace capture shipped
  was answered "No authentication!", indistinguishable from sending no
  credential at all, and retried silently forever.

  The test meant to catch this asserted the wrong header against a stub that
  echoed back whatever it was handed, so it passed for the entire life of the
  bug. It now pins `x-api-key` and asserts no `Authorization` header is sent.

  This fix was written for 0.5.0 and missed the merge, so 0.5.0 shipped the
  broken header. A matching control-plane fix is also required before an upload
  can land: the scope check read a request path Express had already stripped, so
  the `traces:write` carve-out never applied either.

## 0.5.0

- **Widens what counts as a Delphina session.** Reading a knowledge base that
  `sync_knowledge` cached to `.delphina/knowledge/` now makes a session
  eligible, not just calling a Delphina tool. Caching the base so later turns
  can grep it directly is the whole point of the sync skill, and those turns
  carry no MCP attribution — so the sessions most about someone's knowledge
  base were exactly the ones never collected.

  This means **more** sessions upload than before. If you enabled capture under
  the old rule, re-read the scope in the README: a session that greps a base you
  synced last week is now eligible in full, including everything else in it,
  even though it never contacts Delphina.

  Only tools actually pointed at the cache count. The path appears in ordinary
  prose too — our own spec documents it — and reading a document about the cache
  is not reading a knowledge base.

  Deliberately not keyed on `attributionPlugin: "delphina"`, which would have
  been the easy way to catch more. That field names any plugin or skill
  namespace called "delphina", and in a repository with its own
  `.claude/skills/delphina/` it fires constantly for internal work that never
  touches the product — 94% of its occurrences in one real sample.

## 0.4.0

- `DELPHINA_TRACE_DEBUG=1` writes upload outcomes to `~/.delphina/upload.log`,
  one line per turn. The uploader has to stay silent on a normal turn — hook
  output interrupts you, and a non-zero Stop exit traps you in a loop — which
  left no way for anyone, including us, to answer "did that upload?". Statuses,
  byte counts, and skip reasons only: never the transcript, never the token.
- Fixed the uploader reporting `clientVersion: "0.1.0"` on every request. It is
  a separate constant from the manifest and had gone stale since 0.1.0, so the
  one field that identifies a bad client in the field named every client
  identically — including throughout 0.3.0, whose changelog claimed this was
  already fixed. The release check now fails when the two disagree.

## 0.3.0

- **Breaking:** `/delphina:setup` replaces `/delphina:setup-traces`, which is
  gone rather than aliased. One command checks the connection, offers the
  knowledge base, and offers trace capture, rather than a command per feature
  that a new user has no reason to look for.
- The transcript uploader redacts Delphina credentials (`dpk_`, `dsa_`, and
  `Bearer` values) before upload. Setting up trace capture can itself put a
  token in a transcript, and that transcript is what gets uploaded next.
- `/delphina:setup` mints the trace-upload credential itself via the
  `create_trace_upload_token` tool, instead of sending you to the dashboard to
  create one by hand. The minted token carries the `traces:write` scope only,
  which is narrower than what is easy to create by hand — the dashboard's
  default is a full-surface token, and that is the one that would have ended up
  in a file on a laptop.
- Re-running setup on a machine retires that machine's previous token, so
  credentials stop accumulating. It only ever revokes the id recorded locally
  by a previous run, so setting up a second machine leaves the first working.

## 0.2.0

- **Trace capture** (`/delphina:setup-traces`): uploads transcripts of sessions
  that called a Delphina tool, so they can improve the knowledge base your
  team's agent reasons over. Off by default and gated twice — an organization
  setting and a local switch — with `cwd` stripped from every entry before
  upload. Sessions that never call a Delphina tool are never uploaded, and are
  not read at all while capture is off.

  Note the scope before enabling it: a Claude Code transcript is the whole
  session, including your source and the output of your *other* MCP servers, and
  the filter is per session rather than per turn.

- The sync skill picks a workspace via `list_workspaces` when you have not named
  one, rather than requiring you to know its name.

## 0.1.0

- Initial release: bundles the Delphina MCP server so setup is
  `claude plugin install delphina@delphina`.
- `sync-knowledge` skill pulls a commit-pinned snapshot of a workspace's
  knowledge base to `.delphina/knowledge/<workspace-id>/` for local grep/read.
  Snapshots carry a layout version; the plugin refuses an unrecognized one and
  points at `claude plugin update` instead of silently reading the wrong paths.
- `DELPHINA_MCP_URL` overrides the server URL for deployments that do not use
  `https://app.delphina.ai/api/mcp`.
