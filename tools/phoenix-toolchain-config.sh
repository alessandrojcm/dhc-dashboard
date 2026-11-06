#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: bash phoenix-toolchain-config.sh SOURCE_TOML OUTPUT_DIRECTORY" >&2
    exit 1
fi

source_config=$1
output_directory=$2

version_of() {
    local tool=$1 version
    # Read stored TOML values without loading project tasks, env files or hooks.
    version=$(mise --no-config --no-env config get --file "$source_config" "tools.$tool") || return
    case "$version" in
        ''|*[!a-zA-Z0-9._+-]*)
            echo "tools.$tool must be a simple version string in $source_config" >&2
            return 1
            ;;
    esac
    printf '%s' "$version"
}

erlang=$(version_of erlang)
elixir=$(version_of elixir)
fnox=$(version_of fnox)

mkdir -p "$output_directory"
printf '[tools]\nerlang = "%s"\nelixir = "%s"\n' "$erlang" "$elixir" > "$output_directory/beam.toml"
printf '[tools]\nfnox = "%s"\n' "$fnox" > "$output_directory/runtime.toml"
