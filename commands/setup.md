---
description: Set up Delphina in Claude Code — check the connection, pick a workspace, optionally sync the knowledge base and enable trace capture.
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

## 3. Offer trace capture

**Only if they ask, or if they are setting up for a team.** It is off by
default and most people do not need it. Never enable it without an explicit yes.

Explain what it is before asking, and be straight about the scope:

- It sends transcripts of sessions **that used Delphina tools** to their
  organization, where they improve the knowledge base the team's agent reasons
  over.
- A transcript is the **whole session** — their source, their shell output, and
  results from their **other** MCP servers.
- The filter is per session, not per turn: a session that called a Delphina tool
  is eligible in full, including what came before the call.
- Sessions that never call a Delphina tool are never uploaded, and are not read
  at all while capture is off.
- Filesystem paths and Delphina credentials are removed before upload.

If they seem unsure, leave it off. It can be turned on later and nothing else
depends on it.

### If they say yes

**A credential.** They need a token scoped to `traces:write` — one that can
upload transcripts and nothing else. Send them to **Settings → API Key** in
Delphina to create one.

Have them write it straight to disk rather than pasting it to you:

```bash
mkdir -p ~/.delphina && chmod 700 ~/.delphina
touch ~/.delphina/credentials && chmod 600 ~/.delphina/credentials
# paste the token into that file with an editor
```

Do not ask them to paste a token into the conversation. It would land in this
session's transcript — and this is the feature that uploads transcripts. The
uploader redacts Delphina credentials before sending, so a slip is contained,
but it is still on their disk in cleartext and there is no reason to put it
there.

**The local switch.**

```bash
mkdir -p ~/.delphina && printf '{"enabled": true}\n' > ~/.delphina/traces.json
```

Capture is off unless this says otherwise, and it is checked before the
transcript is opened at all.

**The other gate.** Their organization must also accept uploads — an org admin
enables it under **Org Admin → Trace Capture**. Without it the server refuses
and the uploader quietly stops asking. Mention this, because it is the most
common reason nothing happens.

## Turning trace capture off

```bash
printf '{"enabled": false}\n' > ~/.delphina/traces.json
```

Uploads stop immediately and the transcript stops being read. To remove the
credential too: `rm -f ~/.delphina/credentials`. Uninstalling the plugin stops
the hook entirely.

## If uploads are not happening

Each gate is silent by design — a hook's output would interrupt the user — so
check in order:

1. `cat ~/.delphina/traces.json` — is `enabled` true?
2. `ls -l ~/.delphina/credentials` — present and non-empty?
3. Did the session actually call a Delphina tool?
4. `ls ~/.delphina/offsets/` — a `.disabled` file means the server returned 403,
   so the organization has not enabled capture. That is an admin setting.

A number in `~/.delphina/offsets/<session-id>` means an upload was accepted.
