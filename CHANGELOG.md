# Changelog

## 0.1.0 — unreleased

- Initial release: bundles the Delphina MCP server so setup is
  `claude plugin install delphina@delphina`.
- `sync-knowledge` skill pulls a commit-pinned snapshot of a workspace's
  knowledge base to `.delphina/knowledge/<workspace-id>/` for local grep/read.
  Snapshots carry a layout version; the plugin refuses an unrecognized one and
  points at `claude plugin update` instead of silently reading the wrong paths.
- The sync skill picks a workspace via `list_workspaces` when the user has not
  named one, rather than requiring them to know its name.
- Trace capture (`/delphina:setup-traces`): uploads transcripts of sessions that
  called a Delphina tool. Off by default and gated twice — an organization
  setting and a local switch — with `cwd` stripped before upload.
- `DELPHINA_MCP_URL` overrides the server URL for deployments that do not use
  `https://app.delphina.ai/api/mcp`.
