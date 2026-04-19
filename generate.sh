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

GEOSITE_API_BASE="https://surge.bojin.co/geosite"
GEOSITE_INDEX_JSON=""
CLASH_CONFIG_FILE="$ROOT_DIR/clash/config.yaml"
CLASH_GEOSITE_NAMES_FILE=""

FAILED_RULESET_URLS=()

add_failed_ruleset_url() {
  local url="$1"
  FAILED_RULESET_URLS+=("$url")
}

fetch_url_with_retry() {
  local url="$1"
  local max_attempts=3
  local attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    if curl -fsSL "$url"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

prepare_clash_geosite_index() {
  local geosite_dat_url=""
  local dat_tmp=""
  local names_tmp=""

  if ! command -v yq >/dev/null 2>&1; then
    echo "[WARN] yq not found; skip Clash geosite.dat validation." >&2
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "[WARN] curl not found; skip Clash geosite.dat validation." >&2
    return
  fi

  if ! command -v strings >/dev/null 2>&1; then
    echo "[WARN] strings not found; skip Clash geosite.dat validation." >&2
    return
  fi

  geosite_dat_url="$(yq e '.geox-url.geosite // ""' "$CLASH_CONFIG_FILE" 2>/dev/null || true)"
  if [ -z "$geosite_dat_url" ] || [ "$geosite_dat_url" = "null" ]; then
    echo "[WARN] geox-url.geosite not found in $CLASH_CONFIG_FILE; skip Clash geosite.dat validation." >&2
    return
  fi

  dat_tmp="$(mktemp)"
  names_tmp="$(mktemp)"

  if ! fetch_url_with_retry "$geosite_dat_url" > "$dat_tmp"; then
    echo "[WARN] Failed to fetch Clash geosite.dat: $geosite_dat_url; skip validation." >&2
    rm -f "$dat_tmp" "$names_tmp"
    return
  fi

  strings "$dat_tmp" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -n 's/^\([a-z0-9][a-z0-9._-]*\)$/\1/p' \
    | sort -u > "$names_tmp"

  rm -f "$dat_tmp"

  if [ ! -s "$names_tmp" ]; then
    echo "[WARN] Extracted empty geosite index from Clash geosite.dat; skip validation." >&2
    rm -f "$names_tmp"
    return
  fi

  CLASH_GEOSITE_NAMES_FILE="$names_tmp"
}

cleanup_tmp_files() {
  if [ -n "$CLASH_GEOSITE_NAMES_FILE" ] && [ -f "$CLASH_GEOSITE_NAMES_FILE" ]; then
    rm -f "$CLASH_GEOSITE_NAMES_FILE"
  fi
}

trap cleanup_tmp_files EXIT

expand_surge_ruleset_file() {
  local file="$1"
  local tmp_file="${file}.expand.tmp"

  : > "$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      RULE-SET,*)
        local tag url rest
        IFS=',' read -r tag url rest <<< "$line"

        if [ -n "${rest:-}" ]; then
          echo "$line" >> "$tmp_file"
          continue
        fi

        if ! command -v curl >/dev/null 2>&1; then
          echo "$line" >> "$tmp_file"
          echo "[WARN] curl not found; cannot inline RULE-SET: $url" >&2
          add_failed_ruleset_url "$url"
          continue
        fi

        echo "##############################" >> "$tmp_file"
        echo "# RuleSet: $url" >> "$tmp_file"

        if ! fetch_url_with_retry "$url" | tr -d '\r' | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' >> "$tmp_file"; then
          echo "[WARN] Failed to fetch RULE-SET url: $url" >&2
          add_failed_ruleset_url "$url"
          echo "$line" >> "$tmp_file"
        fi
        echo "##############################" >> "$tmp_file"
        ;;
      *)
        echo "$line" >> "$tmp_file"
        ;;
    esac
  done < "$file"

  mv "$tmp_file" "$file"
}

mkdir -p "$SURGE_RULE_DIR"
mkdir -p "$SHADOWROCKET_RULE_DIR"

# Fetch geosite index once to avoid repeated network calls in the loop.
if command -v curl >/dev/null 2>&1; then
  if ! GEOSITE_INDEX_JSON="$(fetch_url_with_retry "$GEOSITE_API_BASE" || true)"; then
    GEOSITE_INDEX_JSON=""
  fi
  if [ -z "$GEOSITE_INDEX_JSON" ]; then
    echo "[WARN] Failed to fetch geosite index: $GEOSITE_API_BASE" >&2
  fi
else
  echo "[WARN] curl not found; cannot fetch geosite index: $GEOSITE_API_BASE" >&2
fi

# Best-effort validation for Clash geosite.dat (does not affect output generation).
prepare_clash_geosite_index

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

  # Shadowrocket copy is done after Surge expansion (see below).

  # Post-process Surge rule-set: convert GEOSITE entries to RULE-SET using Surge-Geosite.
  # If a GEOSITE tag does not exist in the Surge-Geosite index, keep the original
  # GEOSITE line and print a warning to the script output for manual handling.
  tmp_surge_file="$out_file_surge.tmp"
  : > "$tmp_surge_file"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      GEOSITE,*)
        geosite_name="${line#GEOSITE,}"
        # If name has a suffix like prefix@suffix, use prefix for index lookup
        lookup_name="$geosite_name"
        if printf '%s' "$geosite_name" | grep -q '@'; then
          lookup_name="${geosite_name%@*}"
        fi
        lookup_name_lc="$(printf '%s' "$lookup_name" | tr '[:upper:]' '[:lower:]')"

        if [ -n "$CLASH_GEOSITE_NAMES_FILE" ] && ! grep -qx "$lookup_name_lc" "$CLASH_GEOSITE_NAMES_FILE"; then
          echo "[WARN] Possibly missing in Clash geosite.dat: $base_name:$geosite_name" >&2
        fi

        if [ -n "$GEOSITE_INDEX_JSON" ] && printf '%s\n' "$GEOSITE_INDEX_JSON" | grep -qi "\"$lookup_name_lc\""; then
          # URL always keeps the original full name (including suffix if any)
          echo "RULE-SET,${GEOSITE_API_BASE}/$geosite_name" >> "$tmp_surge_file"
        else
          echo "$line" >> "$tmp_surge_file"
          echo "[WARN] Missing GEOSITE mapping: $base_name:$geosite_name" >&2
        fi
        ;;
      *)
        echo "$line" >> "$tmp_surge_file"
        ;;
    esac
  done < "$out_file_surge"

  mv "$tmp_surge_file" "$out_file_surge"

  expand_surge_ruleset_file "$out_file_surge"

  # Shadowrocket reuses the fully-expanded Surge rule set, stripping
  # DOMAIN-WILDCARD (unsupported by Shadowrocket) and GEOSITE leftovers.
  sed -e '/^DOMAIN-WILDCARD,/d' -e '/^GEOSITE,/d' "$out_file_surge" > "$out_file_shadowrocket"
done

if [ "${#FAILED_RULESET_URLS[@]}" -gt 0 ]; then
  echo "[ERROR] Failed to inline the following RULE-SET urls:" >&2
  for url in "${FAILED_RULESET_URLS[@]}"; do
    echo "- $url" >&2
  done
  exit 1
fi
