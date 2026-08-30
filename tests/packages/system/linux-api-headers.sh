#!/usr/bin/env bash
set -euo pipefail

readonly VALIDATION_ROOT="${VALIDATION_ROOT:-/}"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_package_entry() {
    local contents="$1"
    local entry="$2"

    grep -Fqx "${entry}" <<< "${contents}" \
        || die "missing package entry: ${entry}"
}

main() {
    [[ "$#" -eq 1 ]] \
        || die 'linux-api-headers validator expects exactly one package file'

    local -r package_file="$1"
    local package_identity
    local package_contents
    local installed_path
    local -r validation_prefix="${VALIDATION_ROOT%/}"

    [[ "${VALIDATION_ROOT}" == /* ]] \
        || die 'VALIDATION_ROOT must be absolute'
    [[ -f "${package_file}" ]] \
        || die "package file not found: ${package_file}"

    package_identity="$(pacman -Qp "${package_file}")"
    [[ "${package_identity%% *}" == linux-api-headers ]] \
        || die "unexpected package identity: ${package_identity}"

    package_contents="$(bsdtar -tf "${package_file}")"

    require_package_entry \
        "${package_contents}" \
        'usr/include/linux/version.h'
    require_package_entry \
        "${package_contents}" \
        'usr/include/linux/limits.h'
    require_package_entry \
        "${package_contents}" \
        'usr/include/asm/unistd.h'

    if grep -Eq '^usr/(src|lib/modules)/' <<< "${package_contents}"; then
        die 'linux-api-headers must not contain kernel build trees'
    fi

    printf '==> Installing linux-api-headers in the disposable seed\n'
    pacman -U --noconfirm "${package_file}"
    pacman -Q linux-api-headers

    for installed_path in \
        usr/include/linux/version.h \
        usr/include/linux/limits.h \
        usr/include/asm/unistd.h
    do
        [[ -f "${validation_prefix}/${installed_path}" ]] \
            || die "installed header not found: /${installed_path}"
    done

    printf '%s\n' \
        '#include <linux/version.h>' \
        '#include <linux/limits.h>' \
        '#include <asm/unistd.h>' \
        '#ifndef LINUX_VERSION_CODE' \
        '#error LINUX_VERSION_CODE is missing' \
        '#endif' \
        'int main(void) { return 0; }' \
        | cc \
            --sysroot="${VALIDATION_ROOT}" \
            -x c \
            -fsyntax-only \
            -

    printf '==> linux-api-headers validation passed\n'
}

main "$@"
