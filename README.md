# Delphina for Claude Code

Ask [Delphina](https://delphina.ai)'s analytics agent data questions without leaving
your terminal. This plugin bundles the Delphina MCP server configuration, so
connecting is one command instead of hand-editing an MCP config.

Once installed, Claude Code can start a Delphina chat, send follow-up messages,
pull back results, and file issues — the same agent you get in the web app and in
Slack. Delphina answers using your team's warehouse and curated knowledge base;
Claude Code sees the answers, not the underlying data.

It can also sync your **knowledge base** — the curated metrics, tables, notes, and
rules Delphina reasons over — to a local folder, so Claude can grep your team's
definitions directly instead of asking one question at a time. See
[Knowledge sync](#knowledge-sync).

> **Beta.** The Delphina MCP server is in beta and must be enabled for your
> organization. Ask your Delphina administrator if you are not sure whether you
> have access.

## Install

```bash
claude plugin marketplace add delphina-ai/claude-plugin
claude plugin install delphina@delphina
```

If you ran those from inside Claude Code, run `/reload-plugins` to activate the
plugin; from a shell, just start Claude Code. Then run any Delphina tool — the
first call opens a browser to sign in to Delphina, and Claude Code stores the
OAuth credential for you.

To install for a single project rather than for your user account, add
`--scope project` (checked into the repo) or `--scope local` (only you, only this
project) to the `install` command.

### Keeping it up to date

Claude Code disables auto-update for third-party marketplaces by default. We
recommend turning it on so you pick up new Delphina tools as they ship:

1. Run `/plugin` in Claude Code
2. Select **Marketplaces**
3. Choose `delphina`
4. Select **Enable auto-update**

To update by hand instead:

```bash
claude plugin marketplace update delphina
claude plugin update delphina@delphina
```

## Knowledge sync

Ask Claude to "sync the Delphina knowledge base" (or just ask a question about
your metrics) and it will pull a snapshot to
`.delphina/knowledge/<workspace-id>/` — one markdown file per document, laid out
as `<namespace>/<type>/<name>.md`.

You do not have to say which workspace. Claude syncs your default one, and can
call `list_workspaces` to show you the alternatives if you have more than one.

From then on Claude answers definition questions by reading those files, with no
round-trip to Delphina. The cache is git-ignored automatically, so it never lands
in your repository.

Syncs are pinned to a snapshot id and are free when nothing has changed: Claude
sends back the id it already has, and an unchanged knowledge base transfers no
bytes at all. Sync once per session; the snapshot is read-only, and editing the
files changes nothing in Delphina.

Each snapshot declares the directory layout it uses, and the plugin refuses one
it does not understand rather than extracting a tree it would then look for in
the wrong place. If that happens, update the plugin — the error says how.

## Trace capture

**Off by default, and off until two separate people turn it on** — a Delphina
administrator for the organization, and you for this machine. Run
`/delphina:setup-traces` to enable it locally; it explains what is collected
before changing anything.

When capture is on, sessions **that called a Delphina tool** have their
transcript uploaded to your Delphina organization, where they improve the
knowledge base your team's agent reasons over.

Read that scope carefully before enabling it:

- A Claude Code transcript is the whole session — your source, your shell
  output, and the results from your **other** MCP servers — not only the parts
  involving Delphina.
- The filter is per session, not per turn. A session that called a Delphina tool
  is eligible in full, including what came before the call.
- Sessions that never call a Delphina tool are never uploaded, and are not read
  at all while capture is off.
- `cwd` is removed from every entry before upload, so filesystem paths do not
  travel with it.

Turn it off at any time:

```bash
printf '{"enabled": false}\n' > ~/.delphina/traces.json
```

Uninstalling the plugin removes the hook entirely.

## Configuration

The plugin points at Delphina's production MCP server,
`https://app.delphina.ai/api/mcp`. That is the right value for essentially
everyone, and there is nothing to configure.

If Delphina gave you a different URL for your deployment, set `DELPHINA_MCP_URL`
before starting Claude Code:

```bash
export DELPHINA_MCP_URL=https://your-host.example.com/api/mcp
```

To make it stick, put it in your shell profile, or in the `env` block of your
Claude Code [settings file](https://code.claude.com/docs/en/settings):

```json
{
  "env": {
    "DELPHINA_MCP_URL": "https://your-host.example.com/api/mcp"
  }
}
```

### Authorizing without OAuth

OAuth is preferred: there is no long-lived key to copy around, and access follows
your Delphina account. If you are in an environment that cannot complete a browser
sign-in — CI, a headless container — use an API key instead.

In Delphina, go to **Settings → Connect to Delphina MCP → General**, expand
**API Key Authorization**, and copy the **Authorization Header** value. Then
configure the server directly rather than through this plugin:

```bash
claude mcp add --scope user --transport http delphina https://app.delphina.ai/api/mcp \
  --header "Authorization: Bearer YOUR_API_KEY"
```

Treat that key like a password. Do not commit it.

## Deploying to a team

On a Team or Enterprise plan, an administrator can push this marketplace to every
seat through [managed settings](https://code.claude.com/docs/en/permissions#managed-settings),
so engineers do not run the `marketplace add` step themselves:

```json
{
  "extraKnownMarketplaces": {
    "delphina": {
      "source": {
        "source": "github",
        "repo": "delphina-ai/claude-plugin"
      },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "delphina@delphina": true }
}
```

`autoUpdate` turns on background updates fleet-wide, so seats do not have to
toggle it individually.

## What's in here

This repository is both a Claude Code plugin and a single-plugin marketplace:

| Path                              | Purpose                                                       |
| --------------------------------- | ------------------------------------------------------------- |
| `.claude-plugin/plugin.json`      | Plugin manifest — name, version, and metadata                  |
| `.claude-plugin/marketplace.json` | Marketplace catalog listing this plugin at the repository root |
| `.mcp.json`                       | The Delphina MCP server definition                             |
| `skills/sync-knowledge/`          | The knowledge-base sync skill                                  |
| `scripts/apply-snapshot.sh`       | Downloads, version-checks, and atomically installs a snapshot  |
| `commands/setup-traces.md`        | `/delphina:setup-traces` — enable or disable trace capture      |
| `hooks/hooks.json`                | Runs the uploader on Stop and SessionEnd                       |
| `scripts/upload-transcript.sh`    | Uploads the new part of an eligible session's transcript       |

## Support

- Docs: <https://docs.delphina.ai/integrations/delphina-mcp>
- Email: <support@delphina.ai>
- Bugs in the plugin itself: open an issue on this repository.

## License

MIT — see [LICENSE](LICENSE).
