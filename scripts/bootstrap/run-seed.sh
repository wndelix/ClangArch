#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/bootstrap/seed/config.env"

find_engine() {
    if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
        command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1 || {
            printf 'ERROR: CONTAINER_ENGINE=%s was not found.\n' "${CONTAINER_ENGINE}" >&2
            exit 1
        }
        printf '%s\n' "${CONTAINER_ENGINE}"
        return
    fi

    if command -v docker >/dev/null 2>&1; then
        printf '%s\n' docker
        return
    fi

    if command -v podman >/dev/null 2>&1; then
        printf '%s\n' podman
        return
    fi

    printf 'ERROR: Docker or Podman is required.\n' >&2
    exit 1
}

main() {
    local engine
    engine="$(find_engine)"

    mkdir -p "${ROOT_DIR}/out/seed"
    rm -f "${ROOT_DIR}/out/seed/"*.pkg.tar.*

    printf '==> Engine: %s\n' "${engine}"
    printf '==> Seed image: %s\n' "${ARCH_IMAGE}"
    printf '==> Arch snapshot: %s\n' "${ARCH_SNAPSHOT}"

    "${engine}" pull "${ARCH_IMAGE}"

    "${engine}" run \
        --rm \
        --env "ARCH_SNAPSHOT=${ARCH_SNAPSHOT}" \
        --env "HOST_UID=$(id -u)" \
        --env "HOST_GID=$(id -g)" \
        --volume "${ROOT_DIR}:/work" \
        --workdir /work \
        "${ARCH_IMAGE}" \
        /bin/bash /work/scripts/bootstrap/inside-seed.sh
}

main "$@"
