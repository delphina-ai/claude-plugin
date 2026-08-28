# Changelog

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
- `DELPHINA_TRACE_DEBUG=1` writes upload outcomes to `~/.delphina/upload.log`.
  The uploader has to stay silent on a normal turn — hook output interrupts you,
  and a non-zero Stop exit traps you in a loop — which left no way for anyone,
  including us, to answer "did that upload?". Statuses and skip reasons only:
  never the transcript, never the token.
- Fixed the uploader reporting `clientVersion: "0.1.0"` on every request. It is
  a separate constant from the manifest and went stale for the whole 0.2.0 line,
  so the one field that identifies a bad client in the field named every client
  identically. The release check now fails when the two disagree.

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
