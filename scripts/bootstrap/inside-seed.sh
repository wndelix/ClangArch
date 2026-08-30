#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE=/work
readonly OUTPUT_DIR="${WORKSPACE}/out/seed"
readonly SOURCE_CACHE="${WORKSPACE}/.cache/sources"

if (( EUID != 0 )); then
    printf 'ERROR: inside-seed.sh must run as root inside the seed container.\n' >&2
    exit 1
fi

: "${ARCH_SNAPSHOT:?ARCH_SNAPSHOT is required}"
: "${HOST_UID:?HOST_UID is required}"
: "${HOST_GID:?HOST_GID is required}"

printf '==> Pinning Arch repositories to %s\n' "${ARCH_SNAPSHOT}"
printf 'Server = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' \
    "${ARCH_SNAPSHOT}" > /etc/pacman.d/mirrorlist

# Do not install documentation/translations from packages added to the seed.
# This saves space in the container writable layer.
cat >> /etc/pacman.conf <<'EOF_PACMAN'

# bootstrap seed: files irrelevant to package compilation.
NoExtract = usr/share/man/*
NoExtract = usr/share/doc/*
NoExtract = usr/share/info/*
NoExtract = usr/share/locale/*
EOF_PACMAN

printf '==> Updating the pinned seed\n'
pacman -Syu --noconfirm --needed

printf '==> Installing minimal bootstrap tools\n'
pacman -S --noconfirm --needed \
    binutils \
    cmake \
    fakeroot \
    gcc \
    git \
    make \
    ninja \
    patch \
    pkgconf \
    python

# Bootstrap packages intentionally do not emit separate debug packages.
sed -Ei \
    's/^OPTIONS=.*/OPTIONS=(strip !docs !libtool !staticlibs emptydirs zipman purge !debug !lto)/' \
    /etc/makepkg.conf

printf '==> Cleaning pacman downloads and sync databases\n'
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*

printf '==> Creating unprivileged package builder (%s:%s)\n' \
    "${HOST_UID}" "${HOST_GID}"

if getent group "${HOST_GID}" >/dev/null 2>&1; then
    builder_group="$(getent group "${HOST_GID}" | cut -d: -f1)"
else
    builder_group=builder
    groupadd --gid "${HOST_GID}" "${builder_group}"
fi

if getent passwd "${HOST_UID}" >/dev/null 2>&1; then
    builder_user="$(getent passwd "${HOST_UID}" | cut -d: -f1)"
else
    builder_user=builder
    useradd \
        --create-home \
        --uid "${HOST_UID}" \
        --gid "${builder_group}" \
        --shell /bin/bash \
        "${builder_user}"
fi

builder_home="$(getent passwd "${HOST_UID}" | cut -d: -f6)"

install -d \
    -o "${HOST_UID}" \
    -g "${HOST_GID}" \
    "${OUTPUT_DIR}" \
    "${SOURCE_CACHE}"

printf '==> Seed package set\n'
pacman -Q \
    | grep -E '^(binutils|cmake|fakeroot|gcc|git|make|ninja|pacman|pkgconf|python) ' \
    || true

printf '\n==> Building smoke-test package as %s\n' "${builder_user}"
runuser -u "${builder_user}" -- env \
    HOME="${builder_home}" \
    PKGDEST="${OUTPUT_DIR}" \
    SRCDEST="${SOURCE_CACHE}" \
    MAKEFLAGS="-j$(nproc)" \
    bash -lc '
        set -euo pipefail
        cd /work/tests/seed
        makepkg --cleanbuild --clean --force --noconfirm
    '

package="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print -quit)"

if [[ -z "${package}" ]]; then
    printf 'ERROR: makepkg did not produce a package.\n' >&2
    exit 1
fi

printf '\n==> Produced package\n'
pacman -Qp "${package}"

printf '\n==> Package contents\n'
bsdtar -tf "${package}"

bsdtar -tf "${package}" \
    | grep -qx 'usr/bin/clangarch-bootstrap-smoke'

printf '\n==> Installing package inside the disposable seed\n'
pacman -U --noconfirm "${package}"

test_output="$(clangarch-bootstrap-smoke)"
[[ "${test_output}" == 'ClangArch bootstrap seed works!' ]]
printf '%s\n' "${test_output}"

printf '\n==> Seed smoke test PASSED\n'
printf '==> Container filesystem usage at completion\n'
df -h /
