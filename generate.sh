############################################################
# Read rule providers from clash/rule_provider/ and generate
# rule sets for other apps:
# - ./surge/rule_set/
# - ./shadowrocket/rule_set/
############################################################

#!/bin/bash

# Read rule providers from clash/rule_provider/ and generate rule sets for other apps

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASH_RULE_DIR="$ROOT_DIR/clash/rule_provider"
SURGE_RULE_DIR="$ROOT_DIR/surge/rule_set"
SHADOWROCKET_RULE_DIR="$ROOT_DIR/shadowrocket/rule_set"

mkdir -p "$SURGE_RULE_DIR"
mkdir -p "$SHADOWROCKET_RULE_DIR"

for yaml in "$CLASH_RULE_DIR"/*.yaml; do
  [ -e "$yaml" ] || continue

  base_name="$(basename "$yaml" .yaml)"
  out_file_surge="$SURGE_RULE_DIR/$base_name.list"
  out_file_shadowrocket="$SHADOWROCKET_RULE_DIR/$base_name.list"

  echo "Generating $base_name.list for Surge and Shadowrocket"

  # Use yq to safely extract payload entries.
  # This assumes each payload item is a scalar string as in the current rule files.
  # Comments and blank lines are naturally ignored by the YAML parser.
  yq e '.payload[] | select(. != null)' "$yaml" > "$out_file_surge"
  cp "$out_file_surge" "$out_file_shadowrocket"
done
