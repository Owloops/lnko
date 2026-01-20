#!/usr/bin/env bash

set -euo pipefail

REPO="luanvil/lnko"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

setup_colors() {
    if [[ -n "${FORCE_COLOR:-}" ]]; then
        USE_COLOR=true
    elif [[ -n "${NO_COLOR:-}" ]]; then
        USE_COLOR=false
    elif [[ -t 1 ]]; then
        USE_COLOR=true
    else
        USE_COLOR=false
    fi

    if [[ "$USE_COLOR" == true ]]; then
        red=$'\e[31m'
        green=$'\e[32m'
        yellow=$'\e[33m'
        blue=$'\e[34m'
        bold=$'\e[1m'
        reset=$'\e[0m'
    else
        red='' green='' yellow='' blue='' bold='' reset=''
    fi
}

log() {
    local level=$1
    shift
    local color
    case "$level" in
        info) color="$blue" ;;
        success) color="$green" ;;
        warn) color="$yellow" ;;
        error) color="$red" ;;
        *) color="" ;;
    esac
    if [[ "$level" == "error" ]]; then
        printf "%s[%s]%s %s\n" "$color" "$level" "$reset" "$*" >&2
    else
        printf "%s[%s]%s %s\n" "$color" "$level" "$reset" "$*"
    fi
}

detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Linux) PLATFORM_OS="linux" ;;
        Darwin) PLATFORM_OS="darwin" ;;
        *) log error "unsupported os: $os"; exit 1 ;;
    esac

    case "$arch" in
        x86_64) PLATFORM_ARCH="x86_64" ;;
        aarch64 | arm64) PLATFORM_ARCH="arm64" ;;
        *) log error "unsupported architecture: $arch"; exit 1 ;;
    esac

    PLATFORM="${PLATFORM_OS}_${PLATFORM_ARCH}"
    log info "detected platform: $PLATFORM"
}

get_latest_version() {
    log info "fetching latest release"
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    local response

    if ! response=$(curl -fsSL "$url"); then
        log error "failed to fetch release info"
        exit 1
    fi

    VERSION="${response##*\"tag_name\": \"}"
    VERSION="${VERSION%%\"*}"

    if [[ -z "$VERSION" || "$VERSION" == "$response" ]]; then
        log error "failed to parse version"
        exit 1
    fi

    log info "latest version: $VERSION"
}

download_binary() {
    local binary_name="lnko-${PLATFORM}"
    local url="https://github.com/${REPO}/releases/download/${VERSION}/${binary_name}"

    log info "downloading $binary_name"
    if ! curl -fsSL -o "${TMP_DIR}/lnko" "$url"; then
        log error "failed to download binary"
        log info "url: $url"
        exit 1
    fi

    chmod +x "${TMP_DIR}/lnko"
}

install_binary() {
    local install_dir="${HOME}/.local/bin"
    mkdir -p "$install_dir"
    cp "${TMP_DIR}/lnko" "${install_dir}/lnko"
    log success "installed to ${install_dir}/lnko"

    if [[ ":$PATH:" != *":$install_dir:"* ]]; then
        log warn "$install_dir is not in PATH"
        log info "add to your shell config:"
        printf "  export PATH=\"\$PATH:%s\"\n" "$install_dir"
    fi
}

verify_install() {
    if command -v lnko &>/dev/null; then
        log success "lnko $VERSION installed"
        printf "\n%sget started:%s\n" "$bold" "$reset"
        printf "  lnko --help\n"
        printf "\n%sdocs:%s https://github.com/%s\n" "$bold" "$reset" "$REPO"
    fi
}

main() {
    setup_colors
    printf "%slnko installer%s\n\n" "$bold" "$reset"

    detect_platform
    get_latest_version
    download_binary
    install_binary
    verify_install

    exit 0
}

main "$@"
