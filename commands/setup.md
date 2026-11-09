---
description: Set up Delphina in Claude Code — check the connection, pick a workspace, and optionally sync the knowledge base.
---

# Set up Delphina

Walks someone from "the plugin is installed" to "it works." Everything past the
connection check is optional, so ask before each part rather than doing all of
it — most people want one thing.

## 1. Check the connection

Call `list_workspaces`.

- **It returns workspaces** — connected. Show them the list and move on.
- **It prompts for sign-in** — expected on a first run. The browser flow is
  handled by Claude Code; wait for it and retry.
- **It says the account is not enabled for MCP access** — their organization has
  not turned the Delphina MCP server on. That is an administrator setting; tell
  them who to ask rather than trying to work around it.
- **The tool does not exist** — the plugin is installed but not loaded. Ask them
  to run `/reload-plugins`, or restart Claude Code.

If a single workspace comes back, or one is marked `is_default`, say which one
you will use. If several could plausibly match what they work on, ask.

## 2. Offer the knowledge base

Ask whether they want their team's metric, table and rule definitions available
locally. If yes, follow the `sync-knowledge` skill.

Worth saying: it makes definition questions answerable without a round trip, and
the copy is read-only — editing the files changes nothing in Delphina.

## 3. Clean up an older trace-capture setup

Versions of this plugin up to 0.8.0 could upload session transcripts to
Delphina ("trace capture"). This version cannot, and uploads nothing. Check
whether an older version set this machine up for it:

```bash
ls ~/.delphina/credentials ~/.delphina/token-id ~/.delphina/traces.json 2>/dev/null
```

If nothing is listed, skip this step. Otherwise tell them that capture has
stopped, and that the upload credential it left behind is still live on the
server until they revoke it. To retire it:

1. Revoke it in Delphina under **Settings → API Key**. It is the key whose label
   names this machine.
2. Then, only if they say yes, remove the local copies:

```bash
rm -f ~/.delphina/credentials ~/.delphina/token-id ~/.delphina/traces.json
rm -rf ~/.delphina/offsets
```

Revoke first: deleting the files alone leaves the token valid on the server.
Do not print the contents of `~/.delphina/credentials`; it is a secret.
