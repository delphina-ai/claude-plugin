# Changelog

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
