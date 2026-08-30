#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

builder_uid=
builder_gid=
builder_user=
builder_group=
builder_home=

die() {
    local message="$1"
    local exit_status="${2:-1}"

    printf 'ERROR: %s\n' "${message}" >&2
    exit "${exit_status}"
}

require_variable() {
    local name="$1"

    [[ -n "${!name:-}" ]] || die "${name} is required" 64
}

validate_identifier() {
    local kind="$1"
    local value="$2"

    [[ "${value}" =~ ^[a-z0-9][a-z0-9@._+-]*$ ]] \
        || die "invalid ${kind} name: ${value}" 64
}

validate_inputs() {
    local name

    for name in \
        ARCH_SNAPSHOT \
        BUILD_REPOSITORY \
        BUILD_PACKAGE \
        HOST_UID \
        HOST_GID
    do
        require_variable "${name}"
    done

    validate_identifier repository "${BUILD_REPOSITORY}"
    validate_identifier package "${BUILD_PACKAGE}"

    [[ "${HOST_UID}" =~ ^[0-9]+$ ]] \
        || die "HOST_UID must be numeric" 64
    [[ "${HOST_GID}" =~ ^[0-9]+$ ]] \
        || die "HOST_GID must be numeric" 64

    local -r package_dir="${WORKSPACE}/repository/${BUILD_REPOSITORY}/${BUILD_PACKAGE}"
    [[ -f "${package_dir}/PKGBUILD" ]] \
        || die "PKGBUILD not found: ${package_dir}/PKGBUILD" 66

    (( EUID == 0 )) || die 'build-package-in-seed.sh must run as root' 77
}

configure_seed() {
    printf '==> Pinning Arch repositories to %s\n' "${ARCH_SNAPSHOT}"
    printf 'Server = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' \
        "${ARCH_SNAPSHOT}" > /etc/pacman.d/mirrorlist

    printf '%s\n' \
        '' \
        '# bootstrap seed: files irrelevant to package compilation.' \
        'NoExtract = usr/share/man/*' \
        'NoExtract = usr/share/doc/*' \
        'NoExtract = usr/share/info/*' \
        'NoExtract = usr/share/locale/*' \
        >> /etc/pacman.conf

    printf '==> Updating the pinned seed\n'
    pacman -Syu --noconfirm --needed

    printf '==> Installing generic package build tools\n'
    pacman -S --noconfirm --needed \
        base-devel \
        git \
        sudo

    # Bootstrap packages intentionally do not emit separate debug packages.
    sed -Ei \
        's/^OPTIONS=.*/OPTIONS=(strip !docs !libtool !staticlibs emptydirs zipman purge !debug !lto)/' \
        /etc/makepkg.conf
}

select_builder_ids() {
    if [[ "${HOST_UID}" == 0 ]]; then
        builder_uid=1000
        builder_gid=1000
    else
        builder_uid="${HOST_UID}"
        builder_gid="${HOST_GID}"
    fi
}

create_builder() {
    select_builder_ids

    if getent group "${builder_gid}" >/dev/null 2>&1; then
        builder_group="$(getent group "${builder_gid}" | cut -d: -f1)"
    else
        builder_group=package-builder
        groupadd --gid "${builder_gid}" "${builder_group}"
    fi

    if getent passwd "${builder_uid}" >/dev/null 2>&1; then
        builder_user="$(getent passwd "${builder_uid}" | cut -d: -f1)"
    else
        builder_user=package-builder
        useradd \
            --create-home \
            --uid "${builder_uid}" \
            --gid "${builder_group}" \
            --shell /bin/bash \
            "${builder_user}"
    fi

    builder_home="$(getent passwd "${builder_uid}" | cut -d: -f6)"

    printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' \
        "${builder_user}" > /etc/sudoers.d/package-builder
    chmod 0440 /etc/sudoers.d/package-builder
}

prepare_output_directories() {
    local -r build_dir="${WORKSPACE}/out/build/${BUILD_REPOSITORY}/${BUILD_PACKAGE}"
    local -r package_output="${WORKSPACE}/out/packages/${BUILD_REPOSITORY}"
    local -r source_cache="${WORKSPACE}/out/sources"

    install -d \
        -o "${builder_uid}" \
        -g "${builder_gid}" \
        "${build_dir}" \
        "${package_output}" \
        "${source_cache}"
}

list_expected_packages() {
    local -r package_dir="${WORKSPACE}/repository/${BUILD_REPOSITORY}/${BUILD_PACKAGE}"
    local -r build_dir="${WORKSPACE}/out/build/${BUILD_REPOSITORY}/${BUILD_PACKAGE}"
    local -r package_output="${WORKSPACE}/out/packages/${BUILD_REPOSITORY}"
    local -r source_cache="${WORKSPACE}/out/sources"

    runuser -u "${builder_user}" -- env \
        HOME="${builder_home}" \
        BUILDDIR="${build_dir}" \
        PKGDEST="${package_output}" \
        SRCDEST="${source_cache}" \
        PACKAGE_DIR="${package_dir}" \
        LC_ALL=C \
        bash --noprofile --norc -c '
            set -euo pipefail
            cd "${PACKAGE_DIR}"
            makepkg --packagelist
        '
}

build_package() {
    local -r package_dir="${WORKSPACE}/repository/${BUILD_REPOSITORY}/${BUILD_PACKAGE}"
    local -r build_dir="${WORKSPACE}/out/build/${BUILD_REPOSITORY}/${BUILD_PACKAGE}"
    local -r package_output="${WORKSPACE}/out/packages/${BUILD_REPOSITORY}"
    local -r source_cache="${WORKSPACE}/out/sources"

    printf '==> Building %s/%s as %s\n' \
        "${BUILD_REPOSITORY}" "${BUILD_PACKAGE}" "${builder_user}"

    runuser -u "${builder_user}" -- env \
        HOME="${builder_home}" \
        BUILDDIR="${build_dir}" \
        PKGDEST="${package_output}" \
        SRCDEST="${source_cache}" \
        MAKEFLAGS="-j$(nproc)" \
        PACKAGE_DIR="${package_dir}" \
        LC_ALL=C \
        bash --noprofile --norc -c '
            set -euo pipefail
            cd "${PACKAGE_DIR}"
            makepkg \
                --cleanbuild \
                --clean \
                --force \
                --noconfirm \
                --rmdeps \
                --syncdeps
        '
}

validate_packages() {
    local package_file
    local entry_count
    local -r package_output="${WORKSPACE}/out/packages/${BUILD_REPOSITORY}"
    local -r validator="${WORKSPACE}/tests/packages/${BUILD_REPOSITORY}/${BUILD_PACKAGE}.sh"
    shift 0

    (( "$#" > 0 )) || die 'makepkg did not report any package output'

    for package_file in "$@"; do
        [[ "${package_file}" == "${package_output}/"* ]] \
            || die "unexpected package output path: ${package_file}"
        [[ -f "${package_file}" ]] \
            || die "makepkg did not produce: ${package_file}"

        printf '==> Produced package: %s\n' "${package_file}"
        pacman -Qp "${package_file}"

        entry_count="$(bsdtar -tf "${package_file}" | wc -l)"
        (( entry_count > 3 )) \
            || die "package contains too few entries: ${package_file}"
    done

    if [[ -f "${validator}" ]]; then
        printf '==> Running package validator: %s\n' "${validator}"
        bash "${validator}" "$@"
    fi

    chown "${HOST_UID}:${HOST_GID}" "$@"
}

main() {
    local -a package_files

    validate_inputs
    configure_seed
    create_builder
    prepare_output_directories

    mapfile -t package_files < <(list_expected_packages)
    build_package
    validate_packages "${package_files[@]}"

    printf '==> Package build completed\n'
    df -h /
}

main "$@"
