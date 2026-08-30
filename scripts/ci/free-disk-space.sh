#!/usr/bin/env bash
set -euo pipefail

log_disk() {
    printf '\n==> Disk usage\n'
    df -h /
}

remove_path() {
    local path="$1"

    if [[ -e "$path" ]]; then
        printf '==> Removing unused runner payload: %s\n' "$path"
        sudo rm -rf -- "$path"
    fi
}

main() {
    log_disk

    # Keep this list explicit so changes remain auditable.
    remove_path /usr/local/lib/android
    remove_path /usr/share/dotnet
    remove_path /opt/ghc
    remove_path /usr/local/.ghcup
    remove_path /usr/share/swift
    remove_path /usr/local/share/boost
    remove_path /opt/hostedtoolcache/CodeQL

    sudo apt-get clean || true
    sudo rm -rf /var/lib/apt/lists/* || true

    # Remove any preloaded Docker data before pulling the pinned Arch seed.
    docker system prune --all --force --volumes || true

    log_disk
}

main "$@"
