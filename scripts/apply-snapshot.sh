#!/usr/bin/env bash
# Download a Delphina knowledge-base snapshot and install it as the local cache.
#
# The cache is replaced atomically. A half-extracted directory would look to grep
# like a knowledge base that is simply missing documents — worse than having no
# cache at all, because the caller cannot tell the difference. We stage into a
# sibling temp directory and swap only once extraction has fully succeeded, so a
# failed run leaves the previous snapshot exactly as it was.
set -euo pipefail

usage() {
  echo "usage: $0 --url <archive-url> --workspace <workspace-id> --snapshot <snapshot-id> [--root <dir>]" >&2
  exit 2
}

url=""
workspace=""
snapshot=""
root=".delphina/knowledge"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) url="${2:-}"; shift 2 ;;
    --workspace) workspace="${2:-}"; shift 2 ;;
    --snapshot) snapshot="${2:-}"; shift 2 ;;
    --root) root="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$url" && -n "$workspace" && -n "$snapshot" ]] || usage

# The workspace id reaches us from a tool response and becomes a path segment.
# Refuse anything that could climb out of the cache root.
if [[ "$workspace" == *"/"* || "$workspace" == *"\\"* || "$workspace" == *".."* ]]; then
  echo "refusing unsafe workspace id: $workspace" >&2
  exit 1
fi

command -v unzip >/dev/null 2>&1 || { echo "unzip is required but not installed" >&2; exit 1; }

mkdir -p "$root"
dest="$root/$workspace"
staging="$(mktemp -d "${root}/.staging.XXXXXX")"
archive="$staging/snapshot.zip"

cleanup() { rm -rf "$staging"; }
trap cleanup EXIT

# --fail so an expired presigned URL is an error rather than an XML error body
# extracted as though it were the knowledge base.
curl --fail --silent --show-error --location --max-time 300 --output "$archive" "$url"

unzip -q -o "$archive" -d "$staging/tree"

info="$staging/tree/sync-info.json"

# The directory layout inside the snapshot is a contract between the server that
# builds it and this plugin, which tells Claude where to grep. They ship from
# different repositories on different cadences, and plugin auto-update is off by
# default for third-party marketplaces — so a server-side layout change would
# otherwise land as "Claude can no longer find your metrics", with nothing
# reporting an error. Refuse a layout this version does not know.
SUPPORTED_LAYOUTS=" 1 "
layout=""
if [[ -f "$info" ]]; then
  layout="$(tr -d '[:space:]' < "$info" | sed -n 's/.*"layout":\([0-9][0-9]*\).*/\1/p')"
fi

if [[ -z "$layout" ]]; then
  echo "This snapshot does not declare a layout version. It was probably built by" >&2
  echo "a Delphina deployment older than this plugin. Contact support@delphina.ai." >&2
  exit 1
fi

if [[ "$SUPPORTED_LAYOUTS" != *" $layout "* ]]; then
  echo "This knowledge-base snapshot uses layout version $layout, which this" >&2
  echo "version of the Delphina plugin cannot read. Update the plugin:" >&2
  echo >&2
  echo "  claude plugin marketplace update delphina" >&2
  echo "  claude plugin update delphina@delphina" >&2
  exit 1
fi

# The cache is disposable and rebuilt from the server; it must never become part
# of whatever repository the user happens to be working in.
printf '*\n' > "$root/.gitignore"

# The snapshot id, not the commit sha: the same commit renders differently
# depending on the options that produced it, so the id is what makes the next
# sync a no-op.
printf '%s\n' "$snapshot" > "$staging/tree/.snapshot-id"

previous=""
if [[ -d "$dest" ]]; then
  previous="$(mktemp -d "${root}/.previous.XXXXXX")"
  mv "$dest" "$previous/tree"
fi
mv "$staging/tree" "$dest"
if [[ -n "$previous" ]]; then
  rm -rf "$previous"
fi

doc_count="$(find "$dest" -type f -name '*.md' | wc -l | tr -d ' ')"
echo "Installed $doc_count knowledge documents at $dest"

# `omitted` lists document-shaped paths the server could not include. An
# incomplete knowledge base that looks complete is the failure mode this whole
# cache is most exposed to, so surface it rather than letting a later grep come
# back empty and read as "no such metric exists".
omitted="$(tr -d '[:space:]' < "$dest/sync-info.json" 2>/dev/null | sed -n 's/.*"omitted":\[\([^]]*\)\].*/\1/p')"
if [[ -n "$omitted" ]]; then
  echo >&2
  echo "WARNING: the server could not include some documents in this snapshot:" >&2
  printf '  %s\n' "${omitted//,/$'\n  '}" >&2
  echo "Answers drawn from this cache may be incomplete." >&2
fi
