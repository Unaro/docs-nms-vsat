#!/usr/bin/env bash
# Sourced by installers only. Render explicit ${NAME} placeholders, never eval.
HA_ARTIFACTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../artifacts" && pwd)"

install_artifact() {
    install -D -o root -g root -m "${3:-0644}" "$HA_ARTIFACTS_DIR/$1" "$2"
}

render_artifact() {
    local source=$1 destination=$2 mode=${3:-0644} temp key value line token prefix
    temp=$(mktemp) || return 1
    chmod 0600 "$temp"
    # Process only tokens in the original template, not tokens inside replacements.
    while IFS= read -r line || [[ -n $line ]]; do
        while [[ $line =~ \$\{([A-Za-z_][A-Za-z_0-9]*)\} ]]; do
            key=${BASH_REMATCH[1]}; token=${BASH_REMATCH[0]}
            if [[ ! -v $key ]]; then
                echo "[ОШИБКА] Не задана переменная шаблона: $key ($source)" >&2
                rm -f "$temp"; return 1
            fi
            value=${!key}
            if [[ $value == *$'\n'* || $value == *$'\r'* ]]; then
                echo "[ОШИБКА] Значение переменной шаблона содержит перевод строки: $key" >&2
                rm -f "$temp"; return 1
            fi
            prefix=${line%%"$token"*}
            printf '%s%s' "$prefix" "$value" >> "$temp"
            line=${line#*"$token"}
        done
        printf '%s\n' "$line" >> "$temp" || { rm -f "$temp"; return 1; }
    done < "$HA_ARTIFACTS_DIR/$source"
    install -D -o root -g root -m "$mode" "$temp" "$destination"
    local rc=$?
    rm -f "$temp"
    return "$rc"
}
