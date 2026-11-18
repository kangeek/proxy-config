#!/usr/bin/env bash
# Render the templates with <placeholders> into *.local.* files, filling in
# everything from clash/secrets.yaml:
#   clash/config.yaml   -> clash/config.local.yaml
#   surge/default.conf  -> surge/default.local.conf
#   key: value            replaces every <key> placeholder
#   hosts_amy:            node-domain remapping; paste the `hosts:` section of
#   hosts_tag:            the amy / tag subscription as-is under its own key.
#     <node>: <target>    Rendered at "# <hosts>": clash gets both providers
#                         ("node: target"), surge only tag ("node = target"),
#                         because surge no longer uses amy.
#
# Usage: scripts/render.sh [--copy]
#   --copy  also put the rendered clash config on the macOS clipboard (pbcopy)
# Requires yq v4 (mikefarah): brew install yq
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
clash="$root/clash"
surge="$root/surge"
secrets="$clash/secrets.yaml"

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

if yq -e 'has("hosts")' "$secrets" >/dev/null 2>&1; then
  echo "error: \`hosts\` was split into hosts_amy and hosts_tag in $secrets" >&2
  exit 1
fi

# Every top-level key except the hosts_* maps becomes a "key=value" line
# (null -> empty).
yq -r 'to_entries | .[] | select(.key != "hosts_amy" and .key != "hosts_tag")
       | .key + "=" + ((.value // "") | tostring)' "$secrets" > "$tmp/scalars"

if empty="$(grep -E '^[^=]+=$' "$tmp/scalars" | sed 's/=$//' | paste -sd, -)" && [[ -n "$empty" ]]; then
  echo "note: empty value for: $empty" >&2
fi

# dedup <out file> <key>... : merge the given hosts_* maps into "  node: target"
# lines. Exact duplicates are dropped; the same node domain with two different
# targets is an error. Messages carry entry numbers only, never the domains.
dedup() {
  local out="$1" key
  shift
  : > "$tmp/hosts.raw"
  for key in "$@"; do
    yq -r "(.$key // {}) | to_entries | .[]
           | .key + \" \" + ((.value // \"\") | tostring)" "$secrets" >> "$tmp/hosts.raw"
  done
  awk '
    NF != 2 { printf "error: hosts entry %d is not \"<node>: <target>\"\n", NR > "/dev/stderr"; bad = 1; next }
    ($1 in seen) && seen[$1] != $2 { printf "error: hosts entry %d reuses a node with a different target\n", NR > "/dev/stderr"; bad = 1; next }
    !($1 in seen) { seen[$1] = $2; printf "  %s: %s\n", $1, $2 }
    END { exit bad }
  ' "$tmp/hosts.raw" > "$out" || exit 1
}

# clash: amy + tag. surge: tag only, as "node = target" lines for [Host].
dedup "$tmp/hosts.clash" hosts_amy hosts_tag
dedup "$tmp/hosts.tag" hosts_tag
awk '{ sub(/^ +/, ""); i = index($0, ": "); print substr($0, 1, i - 1) " = " substr($0, i + 2) }' \
  "$tmp/hosts.tag" > "$tmp/hosts.surge"

# render <template> <output> <hosts file>
# Replace <key> placeholders, and the "# <hosts>" line with the mappings. Plain
# string replacement via index()/substr(), so values need no escaping.
render() {
  local template="$1" output="$2" hostsfile="$3"
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
  ' "$tmp/scalars" "$hostsfile" "$template" > "$output"

  # Any placeholder left in a non-comment line means a value is missing.
  if left="$(grep -nE '^[[:space:]]*[^#[:space:]].*<[a-z0-9_]+>' "$output")"; then
    echo "error: unresolved placeholders in $output:" >&2
    echo "$left" | sed -E 's/^([0-9]+):.*(<[a-z0-9_]+>).*/  line \1: \2/' >&2
    rm -f "$output"
    exit 1
  fi
}

render "$clash/config.yaml" "$clash/config.local.yaml" "$tmp/hosts.clash"
render "$surge/default.conf" "$surge/default.local.conf" "$tmp/hosts.surge"

nc="$(wc -l < "$tmp/hosts.clash" | tr -d ' ')"
ns="$(wc -l < "$tmp/hosts.surge" | tr -d ' ')"
echo "wrote clash/config.local.yaml ($nc hosts entries) and surge/default.local.conf ($ns hosts entries)"

if [[ "${1:-}" == "--copy" ]]; then
  pbcopy < "$clash/config.local.yaml"
  echo "copied to clipboard"
fi
