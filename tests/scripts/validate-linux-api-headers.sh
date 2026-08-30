#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SUBJECT="${ROOT_DIR}/tests/packages/system/linux-api-headers.sh"

output=
status=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pacman() {
    case "$1" in
        -Qp|-Q)
            printf '%s\n' 'linux-api-headers 7.2.2-1'
            ;;
        -U)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

bsdtar() {
    [[ "$1" == -tf ]] || return 1

    printf '%s\n' \
        '.PKGINFO' \
        'usr/' \
        'usr/include/' \
        'usr/include/linux/version.h' \
        'usr/include/linux/limits.h'

    if [[ "${FAKE_ARCHIVE_MODE:-complete}" != missing-asm ]]; then
        printf '%s\n' 'usr/include/asm/unistd.h'
    fi

    if [[ "${FAKE_ARCHIVE_MODE:-complete}" == forbidden-tree ]]; then
        printf '%s\n' 'usr/src/linux/Makefile'
    fi
}

cc() {
    while IFS= read -r _line; do
        :
    done
}

export -f pacman bsdtar cc

run_validator() {
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
}

assert_status() {
    local expected="$1"

    [[ "${status}" -eq "${expected}" ]] \
        || fail "expected exit status ${expected}, got ${status}; output: ${output}"
}

assert_contains() {
    local expected="$1"

    [[ "${output}" == *"${expected}"* ]] \
        || fail "expected output to contain '${expected}'; output: ${output}"
}

make_validation_root() {
    local validation_root

    validation_root="$(mktemp -d /tmp/linux-api-headers-root.XXXXXX)"
    mkdir -p \
        "${validation_root}/usr/include/asm" \
        "${validation_root}/usr/include/linux"
    : > "${validation_root}/usr/include/asm/unistd.h"
    : > "${validation_root}/usr/include/linux/limits.h"
    : > "${validation_root}/usr/include/linux/version.h"
    printf '%s\n' "${validation_root}"
}

make_package_file() {
    mktemp /tmp/linux-api-headers.XXXXXX.pkg.tar.zst
}

test_accepts_sanitized_headers_package() {
    local package_file
    local validation_root

    package_file="$(make_package_file)"
    validation_root="$(make_validation_root)"

    run_validator env \
        VALIDATION_ROOT="${validation_root}" \
        FAKE_ARCHIVE_MODE=complete \
        bash "${SUBJECT}" "${package_file}"

    assert_status 0
    assert_contains 'linux-api-headers validation passed'
}

test_rejects_missing_representative_header() {
    local package_file
    local validation_root

    package_file="$(make_package_file)"
    validation_root="$(make_validation_root)"

    run_validator env \
        VALIDATION_ROOT="${validation_root}" \
        FAKE_ARCHIVE_MODE=missing-asm \
        bash "${SUBJECT}" "${package_file}"

    assert_status 1
    assert_contains 'missing package entry: usr/include/asm/unistd.h'
}

test_rejects_kernel_build_tree() {
    local package_file
    local validation_root

    package_file="$(make_package_file)"
    validation_root="$(make_validation_root)"

    run_validator env \
        VALIDATION_ROOT="${validation_root}" \
        FAKE_ARCHIVE_MODE=forbidden-tree \
        bash "${SUBJECT}" "${package_file}"

    assert_status 1
    assert_contains 'must not contain kernel build trees'
}

main() {
    test_accepts_sanitized_headers_package
    test_rejects_missing_representative_header
    test_rejects_kernel_build_tree
    printf 'PASS: linux-api-headers validator\n'
}

main "$@"
