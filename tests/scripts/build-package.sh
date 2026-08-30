#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SUBJECT="${ROOT_DIR}/scripts/build-package.sh"

output=
status=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

run_subject() {
    set +e
    output="$(
        CONTAINER_ENGINE=/bin/echo \
            bash "${SUBJECT}" "$@" 2>&1
    )"
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

test_requires_repository_and_package() {
    run_subject

    assert_status 64
    assert_contains 'Usage:'
}

test_rejects_path_traversal() {
    run_subject system ../linux-api-headers

    assert_status 64
    assert_contains 'invalid package name'
}

test_rejects_missing_package() {
    run_subject system package-that-does-not-exist

    assert_status 66
    assert_contains 'PKGBUILD not found'
}

test_runs_pinned_seed_for_valid_package() {
    run_subject system linux-api-headers

    assert_status 0
    assert_contains 'pull archlinux:base-20260823.0.578598'
    assert_contains 'run --rm'
    assert_contains '--env ARCH_SNAPSHOT=2026/08/23'
    assert_contains '--env BUILD_REPOSITORY=system'
    assert_contains '--env BUILD_PACKAGE=linux-api-headers'
    assert_contains "--volume ${ROOT_DIR}:/work"
    assert_contains '/bin/bash /work/scripts/bootstrap/build-package-in-seed.sh'
}

main() {
    test_requires_repository_and_package
    test_rejects_path_traversal
    test_rejects_missing_package
    test_runs_pinned_seed_for_valid_package
    printf 'PASS: build-package interface\n'
}

main "$@"
