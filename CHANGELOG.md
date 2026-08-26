# Changelog

## 0.1.0 — unreleased

- Initial release: bundles the Delphina MCP server so setup is
  `claude plugin install delphina@delphina`.
- `sync-knowledge` skill pulls a commit-pinned snapshot of a workspace's
  knowledge base to `.delphina/knowledge/<workspace-id>/` for local grep/read.
  Snapshots carry a layout version; the plugin refuses an unrecognized one and
  points at `claude plugin update` instead of silently reading the wrong paths.
- `DELPHINA_MCP_URL` overrides the server URL for deployments that do not use
  `https://app.delphina.ai/api/mcp`.
