# Delphina for Claude Code

Ask [Delphina](https://delphina.ai)'s analytics agent data questions without leaving
your terminal. This plugin bundles the Delphina MCP server configuration, so
connecting is one command instead of hand-editing an MCP config.

Once installed, Claude Code can start a Delphina chat, send follow-up messages,
pull back results, and file issues — the same agent you get in the web app and in
Slack. Delphina answers using your team's warehouse and curated knowledge base;
Claude Code sees the answers, not the underlying data.

It can also read your **knowledge base** — the curated metrics, tables, notes, and
rules Delphina reasons over. Claude searches it for a one-off definition, or syncs
it to a local folder and greps your team's definitions directly. See
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
plugin; from a shell, just start Claude Code. Then run `/delphina:setup`, which
checks the connection and walks through the optional pieces. Then run any Delphina tool — the
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

For a single question, such as how a metric is defined or which table holds a
column, Claude searches the knowledge base with `search_knowledge` and reads only
the documents it needs. Nothing is downloaded.

When a session leans on your definitions throughout, or when you ask Claude to
"sync the Delphina knowledge base", it pulls a snapshot to
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

## Configuration

The plugin points at Delphina's production MCP server,
`https://app.delphina.ai/api/mcp`. That is the right value for essentially
everyone, and there is nothing to configure.

If Delphina gave you a different URL for your deployment, add that server
yourself:

```bash
claude mcp add --scope user --transport http delphina https://your-host.example.com/api/mcp
```

Then run `/mcp`, select `plugin:delphina:delphina`, and disable it, so Claude
does not see two sets of Delphina tools. The setup command and knowledge sync
both work with a server you added this way.

### Authorizing without OAuth

OAuth is preferred: there is no long-lived key to copy around, and access follows
your Delphina account. If you are in an environment that cannot complete a browser
sign-in — CI, a headless container — configure the server with an API key
directly rather than through this plugin. The
[API key authorization](https://docs.delphina.ai/integrations/delphina-mcp#api-key-authorization)
section of the Delphina docs shows how.

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

## Where it works

Everything above is for Claude Code. If you add the plugin from Anthropic's
directory on claude.ai, it also loads in Cowork and in chat, with less:

- **Chat:** the Delphina MCP server appears as a connector you connect on the
  plugin's **Connectors** tab. Knowledge search works there, because it is only
  connector tools. Knowledge sync needs a local shell, so it does nothing
  useful there.
- **Cowork:** the MCP server and the skills load.

## What it sends and fetches

- **The MCP server** at `https://app.delphina.ai/api/mcp`, for every Delphina
  tool call, using the OAuth credential Claude Code stores.
- **Knowledge snapshots**, downloaded with `curl` by the sync-knowledge skill
  from the short-lived Amazon S3 URL that `sync_knowledge` returns, and
  unpacked into `.delphina/knowledge/` in your project.

Nothing else leaves your machine.

## What's in here

This repository is both a Claude Code plugin and a single-plugin marketplace.
It holds no scripts or hooks: everything the plugin does runs through the MCP
server or through instructions in its skill and command.

| Path                              | Purpose                                                       |
| --------------------------------- | ------------------------------------------------------------- |
| `.claude-plugin/plugin.json`      | Plugin manifest — name, version, and metadata                  |
| `.claude-plugin/marketplace.json` | Marketplace catalog listing this plugin at the repository root |
| `.mcp.json`                       | The Delphina MCP server definition                             |
| `skills/sync-knowledge/`          | Knowledge-base search, and the sync that installs a snapshot   |
| `commands/setup.md`               | `/delphina:setup` — connection check and knowledge base        |

## Trace capture

Versions up to 0.8.0 could upload transcripts of sessions that used Delphina
to your organization. That feature ran as a hook, which Anthropic's plugin
directory does not accept from us, so 0.9.0 removed it. If you turned it on
before, run `/delphina:setup` once: it finds the credential that setup left
behind and walks you through revoking it.

## Support

- Docs: <https://docs.delphina.ai/integrations/delphina-mcp>
- Email: <support@delphina.ai>
- Bugs in the plugin itself: open an issue on this repository.

## License

MIT — see [LICENSE](LICENSE).
