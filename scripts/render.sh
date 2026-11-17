#!/usr/bin/env bash
# Render clash/config.yaml (template with <placeholders>) into
# clash/config.local.yaml, filling in everything from clash/secrets.yaml:
#   key: value            replaces every <key> placeholder
#   hosts:                node-domain remapping; paste the `hosts:` section of
#     <node>: <target>    a provider subscription as-is. Rendered at "# <hosts>".
#
# Usage: scripts/render.sh [--copy]
#   --copy  also put the rendered config on the macOS clipboard (pbcopy)
# Requires yq v4 (mikefarah): brew install yq
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
clash="$root/clash"
template="$clash/config.yaml"
secrets="$clash/secrets.yaml"
output="$clash/config.local.yaml"

if ! command -v yq >/dev/null; then
  echo "yq is required (brew install yq)" >&2
  exit 1
fi
if [[ ! -f "$secrets" ]]; then
  echo "missing $secrets (copy clash/secrets.yaml.example and fill it in)" >&2
  exit 1
fi
if ! yq -e 'tag == "!!map"' "$secrets" >/dev/null 2>&1; then
  echo "error: $secrets is not a valid yaml mapping" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Every top-level key except `hosts` becomes a "key=value" line (null -> empty).
yq -r 'to_entries | .[] | select(.key != "hosts")
       | .key + "=" + ((.value // "") | tostring)' "$secrets" > "$tmp/scalars"

# `hosts` entries as "<node domain> <target domain>" lines.
yq -r '(.hosts // {}) | to_entries | .[]
       | .key + " " + ((.value // "") | tostring)' "$secrets" > "$tmp/hosts.raw"

# Exact duplicates are dropped; the same node domain with two different targets
# is an error. Messages carry entry numbers only, never the domains.
awk '
  NF != 2 { printf "error: hosts entry %d is not \"<node>: <target>\"\n", NR > "/dev/stderr"; bad = 1; next }
  ($1 in seen) && seen[$1] != $2 { printf "error: hosts entry %d reuses a node with a different target\n", NR > "/dev/stderr"; bad = 1; next }
  !($1 in seen) { seen[$1] = $2; printf "  %s: %s\n", $1, $2 }
  END { exit bad }
' "$tmp/hosts.raw" > "$tmp/hosts.dedup" || exit 1

if empty="$(grep -E '^[^=]+=$' "$tmp/scalars" | sed 's/=$//' | paste -sd, -)" && [[ -n "$empty" ]]; then
  echo "note: empty value for: $empty" >&2
fi

# Replace <key> placeholders, and the "# <hosts>" line with the mappings. Plain
# string replacement via index()/substr(), so values need no escaping.
awk '
  FILENAME == ARGV[1] {
    i = index($0, "=")
    if (i > 0) sec[substr($0, 1, i - 1)] = substr($0, i + 1)
    next
  }
  FILENAME == ARGV[2] { hosts = hosts $0 "\n"; next }
  {
    if ($0 ~ /^[[:space:]]*# <hosts>[[:space:]]*$/) { printf "%s", hosts; next }
    for (k in sec) {
      ph = "<" k ">"; out = ""; s = $0
      while ((p = index(s, ph)) > 0) { out = out substr(s, 1, p - 1) sec[k]; s = substr(s, p + length(ph)) }
      $0 = out s
    }
    print
  }
' "$tmp/scalars" "$tmp/hosts.dedup" "$template" > "$output"

# Any placeholder left in a non-comment line means a value is missing.
if left="$(grep -nE '^[[:space:]]*[^#[:space:]].*<[a-z0-9_]+>' "$output")"; then
  echo "error: unresolved placeholders in $output:" >&2
  echo "$left" | sed -E 's/^([0-9]+):.*(<[a-z0-9_]+>).*/  line \1: \2/' >&2
  rm -f "$output"
  exit 1
fi

echo "wrote $output ($(wc -l < "$tmp/hosts.dedup" | tr -d ' ') hosts entries)"

if [[ "${1:-}" == "--copy" ]]; then
  pbcopy < "$output"
  echo "copied to clipboard"
fi
