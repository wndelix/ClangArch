#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/bootstrap/seed/config.env"

usage() {
    printf 'Usage: %s <repository> <package>\n' "${0##*/}" >&2
}

die() {
    local message="$1"
    local exit_status="${2:-1}"

    printf 'ERROR: %s\n' "${message}" >&2
    exit "${exit_status}"
}

validate_identifier() {
    local kind="$1"
    local value="$2"

    [[ "${value}" =~ ^[a-z0-9][a-z0-9@._+-]*$ ]] \
        || die "invalid ${kind} name: ${value}" 64
}

find_engine() {
    if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
        command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1 \
            || die "CONTAINER_ENGINE=${CONTAINER_ENGINE} was not found."
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

    die 'Docker or Podman is required.'
}

main() {
    [[ "$#" -eq 2 ]] || {
        usage
        exit 64
    }

    local -r repository="$1"
    local -r package="$2"
    local -r package_dir="${ROOT_DIR}/repository/${repository}/${package}"
    local engine

    validate_identifier repository "${repository}"
    validate_identifier package "${package}"

    [[ -f "${package_dir}/PKGBUILD" ]] \
        || die "PKGBUILD not found: ${package_dir}/PKGBUILD" 66

    : "${ARCH_IMAGE:?ARCH_IMAGE is required}"
    : "${ARCH_SNAPSHOT:?ARCH_SNAPSHOT is required}"

    engine="$(find_engine)"

    mkdir -p \
        "${ROOT_DIR}/out/build/${repository}/${package}" \
        "${ROOT_DIR}/out/packages/${repository}" \
        "${ROOT_DIR}/out/sources"

    printf '==> Package: %s/%s\n' "${repository}" "${package}"
    printf '==> Engine: %s\n' "${engine}"
    printf '==> Seed image: %s\n' "${ARCH_IMAGE}"
    printf '==> Arch snapshot: %s\n' "${ARCH_SNAPSHOT}"

    "${engine}" pull "${ARCH_IMAGE}"

    "${engine}" run \
        --rm \
        --env "ARCH_SNAPSHOT=${ARCH_SNAPSHOT}" \
        --env "BUILD_REPOSITORY=${repository}" \
        --env "BUILD_PACKAGE=${package}" \
        --env "HOST_UID=$(id -u)" \
        --env "HOST_GID=$(id -g)" \
        --volume "${ROOT_DIR}:/work" \
        --workdir /work \
        "${ARCH_IMAGE}" \
        /bin/bash /work/scripts/bootstrap/build-package-in-seed.sh
}

main "$@"
