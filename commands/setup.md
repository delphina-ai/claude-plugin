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
- The filter is per session, not per turn: a session that used Delphina is
  eligible in full, including what came before it did.
- "Used Delphina" means calling a Delphina tool **or** running a tool against a
  knowledge base cached under `.delphina/knowledge/`. Grepping a base they
  synced earlier counts, even with no call to Delphina in that session.
- Sessions that do neither are never uploaded, and are not read at all while
  capture is off.
- Filesystem paths and Delphina credentials are removed before upload.

If they seem unsure, leave it off. It can be turned on later and nothing else
depends on it.

### If they say yes

**The credential.** Call `create_trace_upload_token`. It returns a token scoped
to `traces:write` and nothing else — it cannot read their chats, write to the
knowledge base, or file issues.

Pass a `label` naming this machine ("work laptop"), so a user with several
machines can tell the tokens apart later and revoke just one.

If `~/.delphina/token-id` already exists, this machine was set up before. Pass
its contents as `replaces_token_id` so the old credential is retired instead of
being left live forever:

```bash
cat ~/.delphina/token-id 2>/dev/null
```

Only ever pass an id that came from that file. It is how this machine retires
its own predecessor, not a general revoke — an id from anywhere else is either
a no-op or someone else's problem.

**Write it to disk without echoing it.** The token is a secret and this is the
feature that uploads transcripts, so do not print it, summarize it, or paste it
into a command whose output is shown. Write it directly:

```bash
mkdir -p ~/.delphina && chmod 700 ~/.delphina
touch ~/.delphina/credentials && chmod 600 ~/.delphina/credentials
```

Then write the `token` value into `~/.delphina/credentials` and the `token_id`
value into `~/.delphina/token-id`, each on its own line with no other content.

The uploader redacts Delphina credentials before sending, so a slip is
contained rather than published — but that is a backstop, not a reason to be
casual.

**The local switch.**

```bash
mkdir -p ~/.delphina && printf '{"enabled": true}\n' > ~/.delphina/traces.json
```

Capture is off unless this says otherwise, and it is checked before the
transcript is opened at all.

**The other gate.** Check `organization_capture_enabled` in the tool's response.
When it is `false`, the credential is valid but the server will refuse uploads
until an org admin enables capture under **Org Admin → Trace Capture**. Say so
plainly — it is the most common reason nothing happens, and the user cannot fix
it themselves.

## Turning trace capture off

```bash
printf '{"enabled": false}\n' > ~/.delphina/traces.json
```

Uploads stop immediately and the transcript stops being read.

To retire the credential as well, revoke it in Delphina under **Settings → API
Key** (find it by the label given at setup), then remove the local copies:

```bash
rm -f ~/.delphina/credentials ~/.delphina/token-id
```

Deleting the files alone leaves the token live on the server, so revoke first.
Uninstalling the plugin stops the hook entirely.

## If uploads are not happening

Each gate is silent by design — a hook's output would interrupt the user — so
check in order:

1. `cat ~/.delphina/traces.json` — is `enabled` true?
2. `ls -l ~/.delphina/credentials` — present and non-empty?
3. Did the session actually call a Delphina tool?
4. `ls ~/.delphina/offsets/` — a `.disabled` file means the server returned 403,
   so the organization has not enabled capture. That is an admin setting.
5. Was the credential revoked? Re-running setup on this machine retires the
   previous token, so a second machine sharing a copied credentials file stops
   working. Each machine should run setup and hold its own token.

A number in `~/.delphina/offsets/<session-id>` means an upload was accepted.
