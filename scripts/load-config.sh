#!/usr/bin/env bash

# Load config.ini without eval or execution of configuration values.
# PROJECT_ROOT must be set by the calling script. SCAN_CONFIG may select an
# alternative file, and existing variables take precedence over file values.

CONFIG_FILE="${SCAN_CONFIG:-$PROJECT_ROOT/config.ini}"

if [[ ! -r "$CONFIG_FILE" ]]; then
    printf 'ERROR: cannot read configuration: %s\n' "$CONFIG_FILE" >&2
    return 1 2>/dev/null || exit 1
fi

while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    config_line="${config_line%$'\r'}"
    config_line="${config_line#"${config_line%%[![:space:]]*}"}"
    config_line="${config_line%"${config_line##*[![:space:]]}"}"

    [[ -z "$config_line" || "$config_line" == \#* || "$config_line" == \;* ]] && continue
    [[ "$config_line" =~ ^\[[A-Za-z0-9_-]+\]$ ]] && continue

    if [[ "$config_line" =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        config_key="${BASH_REMATCH[1]}"
        config_value="${BASH_REMATCH[2]}"
        config_value="${config_value%"${config_value##*[![:space:]]}"}"

        if [[ ! -v "$config_key" ]]; then
            printf -v "$config_key" '%s' "$config_value"
        fi
    else
        printf 'ERROR: invalid configuration line in %s: %s\n' \
            "$CONFIG_FILE" "$config_line" >&2
        return 1 2>/dev/null || exit 1
    fi
done < "$CONFIG_FILE"

unset config_line config_key config_value
