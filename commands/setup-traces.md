---
description: Turn on Delphina trace capture for this machine, or turn it back off. Mints a narrow upload credential and records the local switch.
---

# Set up Delphina trace capture

Trace capture sends transcripts of sessions **that used Delphina tools** to your
Delphina organization, where they improve the knowledge base your team's agent
reasons over.

Before doing anything, make sure the user understands what they are turning on,
because it is broader than it first sounds:

- A Claude Code transcript contains the whole session — your source code, shell
  output, and the results from **your other MCP servers** — not just the parts
  involving Delphina.
- The filter is per **session**, not per turn. If a session called a Delphina
  tool at any point, that session's full transcript is eligible, including the
  parts before the call.
- Sessions that never call a Delphina tool are never uploaded, and are never
  even read while capture is off.

Say that plainly and get a clear yes before continuing. If the user seems
unsure, leave it off — it can be enabled later and nothing else depends on it.

## Turning it on

**1. Check whether the organization allows it.**

Capture also has to be enabled by a Delphina administrator, separately from this
machine. If it is off there, uploads are refused and this setup does nothing
useful — so it is worth saying up front that they may need to ask their admin.

**2. Mint an upload credential.**

Direct the user to **Settings → API Key** in Delphina and have them create a
token. It needs the `traces:write` scope and nothing else — a token scoped that
way can upload transcripts and cannot read chats, write knowledge, or act as
them anywhere else.

Do not ask them to paste the token into the conversation. A secret in the
transcript is a secret in a file on disk, and — if capture is already on for
another session — a secret in an upload. Have them write it directly:

```bash
mkdir -p ~/.delphina && touch ~/.delphina/credentials && chmod 600 ~/.delphina/credentials
# then paste the token into that file with an editor
```

**3. Record the local switch.**

```bash
mkdir -p ~/.delphina && printf '{"enabled": true}\n' > ~/.delphina/traces.json
```

Capture is off unless this file says otherwise. It is checked before anything
else — while it is off, the uploader does not open the transcript at all.

**4. Confirm.**

```bash
ls -l ~/.delphina/credentials ~/.delphina/traces.json
```

Tell the user capture starts with their next session, and that they can turn it
off at any time with the command below.

## Turning it off

```bash
printf '{"enabled": false}\n' > ~/.delphina/traces.json
```

That is sufficient — uploads stop immediately, and the transcript stops being
read. To also remove the credential:

```bash
rm -f ~/.delphina/credentials
```

Removing the plugin entirely stops the hook from running at all.

## If uploads are not happening

Check in this order, since each gate is silent by design — the uploader never
writes to stdout, because a hook's output interrupts the user:

1. `cat ~/.delphina/traces.json` — is `enabled` true?
2. `ls -l ~/.delphina/credentials` — does it exist and is it non-empty?
3. Did the session actually call a Delphina tool? Sessions that did not are
   never uploaded.
4. `ls ~/.delphina/offsets/` — a `.disabled` file for a session means the server
   returned 403, which means the organization has not enabled capture. That is
   an administrator setting, not a local one.
