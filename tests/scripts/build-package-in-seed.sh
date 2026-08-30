#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SUBJECT="${ROOT_DIR}/scripts/bootstrap/build-package-in-seed.sh"

output=
status=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

run_subject() {
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

test_requires_snapshot() {
    run_subject env \
        -u ARCH_SNAPSHOT \
        BUILD_REPOSITORY=system \
        BUILD_PACKAGE=linux-api-headers \
        HOST_UID=1000 \
        HOST_GID=1000 \
        bash "${SUBJECT}"

    assert_status 64
    assert_contains 'ARCH_SNAPSHOT is required'
}

test_rejects_path_traversal() {
    run_subject env \
        ARCH_SNAPSHOT=2026/08/23 \
        BUILD_REPOSITORY=system \
        BUILD_PACKAGE=../linux-api-headers \
        HOST_UID=1000 \
        HOST_GID=1000 \
        bash "${SUBJECT}"

    assert_status 64
    assert_contains 'invalid package name'
}

test_rejects_missing_pkgbuild() {
    run_subject env \
        ARCH_SNAPSHOT=2026/08/23 \
        BUILD_REPOSITORY=system \
        BUILD_PACKAGE=package-that-does-not-exist \
        HOST_UID=1000 \
        HOST_GID=1000 \
        bash "${SUBJECT}"

    assert_status 66
    assert_contains 'PKGBUILD not found'
}

test_requires_root_after_validating_input() {
    if (( EUID == 0 )); then
        return
    fi

    run_subject env \
        ARCH_SNAPSHOT=2026/08/23 \
        BUILD_REPOSITORY=system \
        BUILD_PACKAGE=linux-api-headers \
        HOST_UID="$(id -u)" \
        HOST_GID="$(id -g)" \
        bash "${SUBJECT}"

    assert_status 77
    assert_contains 'must run as root'
}

main() {
    test_requires_snapshot
    test_rejects_path_traversal
    test_rejects_missing_pkgbuild
    test_requires_root_after_validating_input
    printf 'PASS: in-seed input validation\n'
}

main "$@"
