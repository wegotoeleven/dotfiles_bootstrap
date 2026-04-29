#!/usr/bin/env bash
#
# Clones the dotfiles repo and checks out only the catalog items listed
# in this host's manifest.

set -euo pipefail

readonly REPO_URL="git@github.com:wegotoeleven/dotfiles.git"
readonly DEFAULT_DOTFILES_DIR="${HOME}/.dotfiles"

# Set by clone_dotfiles(); used in main() for the next-steps message.
DOTFILES_DIR=""

# File descriptor for interactive prompts (0 = stdin, 3 = /dev/tty).
# TTY_FD_OPENED tracks whether we opened /dev/tty so cleanup_prompt_fd()
# can close it.
PROMPT_FD=0
TTY_FD_OPENED=0

fatal() {
    echo "Fatal: ${*}" >&2
    exit 1
}

info() {
    echo "==> ${*}"
}

# Returns the normalised OS name: "macos" or "linux".
detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       fatal "Unsupported OS: $(uname -s)." ;;
    esac
}

# Ensures git is available, installing Xcode Command Line Tools or
# apt packages as needed.
# Args: $1 — OS name as returned by detect_os.
ensure_dependencies() {
    local os="${1}"

    if [[ "${os}" == "macos" ]]; then
        if ! xcode-select -p &>/dev/null; then
            info "Xcode Command Line Tools not found. Installing..."

            # softwareupdate works headlessly; xcode-select --install
            # requires a GUI. The sentinel causes softwareupdate to
            # surface the CLT package.
            local sentinel
            sentinel="/tmp/.com.apple.dt.CommandLineTools"
            sentinel+=".installondemand.in-progress"
            touch "${sentinel}"

            local pkg
            pkg=$(softwareupdate -l 2>/dev/null \
                | grep '\* Label: Command Line Tools' \
                | sed 's/.*Label: //' \
                | sort | tail -n 1)

            if [[ -z "${pkg}" ]]; then
                rm -f "${sentinel}"
                fatal "Could not find Command Line Tools in softwareupdate."
            fi

            info "Installing: ${pkg}"
            sudo softwareupdate -i "${pkg}" --verbose
            rm -f "${sentinel}"

            xcode-select -p &>/dev/null \
                || fatal "Xcode Command Line Tools installation failed."
            info "Xcode Command Line Tools installation complete."
        fi

        command -v git &>/dev/null \
            || fatal "git not found after installing Xcode Command Line Tools."

    elif [[ "${os}" == "linux" ]]; then
        if ! command -v git &>/dev/null; then
            info "git not found. Attempting to install..."
            if command -v apt-get &>/dev/null; then
                sudo apt-get update && sudo apt-get install -y git
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y git
            elif command -v yum &>/dev/null; then
                sudo yum install -y git
            else
                fatal "Cannot install git automatically; install it manually."
            fi
        fi
    fi

    info "Dependencies verified: git available."
}

# Opens /dev/tty as FD 3 if stdin is not a terminal (e.g. curl | bash).
setup_prompt_fd() {
    if [[ -t 0 ]]; then
        PROMPT_FD=0
    elif [[ -r /dev/tty ]]; then
        exec 3</dev/tty
        PROMPT_FD=3
        TTY_FD_OPENED=1
    else
        fatal "No interactive terminal detected; cannot prompt for input."
    fi
}

# Closes FD 3 if setup_prompt_fd() opened it.
cleanup_prompt_fd() {
    if [[ "${TTY_FD_OPENED}" -eq 1 ]]; then
        exec 3<&-
    fi
}

# Prompt the user for input and store the result in a named variable.
# Args: $1 — name of the variable to assign the result to.
#       $2 — prompt string.
prompt_read() {
    local __result_var="${1}"
    local __prompt="${2}"
    local __input=""

    printf "%s" "${__prompt}" >&2
    if [[ "${PROMPT_FD}" -eq 0 ]]; then
        read -r __input
    else
        read -r -u "${PROMPT_FD}" __input
    fi

    printf -v "${__result_var}" '%s' "${__input}"
}

# Returns 0 if $1 is a path safe to clone into (absent or empty directory).
# Args: $1 — target path (tilde expansion is applied).
check_directory() {
    local dir="${1/#\~/${HOME}}"

    [[ -e "${dir}" ]] || return 0

    if [[ ! -d "${dir}" ]]; then
        echo "Error: ${dir} exists but is not a directory." >&2
        return 1
    fi

    if [[ -n "$(ls -A "${dir}" 2>/dev/null)" ]]; then
        echo "Error: ${dir} exists and is not empty." >&2
        return 1
    fi

    return 0
}

# Clones the dotfiles repo with a sparse checkout of only the catalog
# items listed in this machine's manifest.
# Sets the DOTFILES_DIR global and changes the working directory on success.
clone_dotfiles() {
    local dotfiles_dir
    local prompt

    while true; do
        prompt="Where should dotfiles be cloned? [${DEFAULT_DOTFILES_DIR}]: "
        prompt_read dotfiles_dir "${prompt}"
        dotfiles_dir="${dotfiles_dir:-${DEFAULT_DOTFILES_DIR}}"
        check_directory "${dotfiles_dir}" && break
        echo "Please try again."
        echo
    done

    dotfiles_dir="${dotfiles_dir/#\~/${HOME}}"
    mkdir -p "$(dirname "${dotfiles_dir}")"

    local hostname
    hostname="$(hostname -s)"
    info "Host: ${hostname}"

    info "Cloning dotfiles to ${dotfiles_dir}..."
    git clone --filter=blob:none --no-checkout "${REPO_URL}" "${dotfiles_dir}"
    cd "${dotfiles_dir}" || fatal "Failed to cd to ${dotfiles_dir}."

    # Sparse-checkout manifests/ only so we can verify this host has one.
    info "Checking for manifest..."
    git sparse-checkout init --cone
    git sparse-checkout set manifests
    git checkout

    local manifest="${dotfiles_dir}/manifests/${hostname}"
    [[ -f "${manifest}" ]] \
        || fatal "No manifest found for host '${hostname}'." \
                 "Create manifests/${hostname} in the dotfiles repo first."

    # Read catalog items from the manifest.
    local items=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] && items+=("${line}")
    done < "${manifest}"

    [[ ${#items[@]} -gt 0 ]] || fatal "Manifest for '${hostname}' is empty."

    # Expand sparse checkout to include all required catalog items.
    local sparse_dirs=("manifests" "dotbot")
    local item
    for item in "${items[@]}"; do
        sparse_dirs+=("catalog/${item}")
    done

    info "Checking out catalog items: ${items[*]}"
    git sparse-checkout set --skip-checks "${sparse_dirs[@]}"
    git checkout
    git submodule update --init --recursive \
        || fatal "Failed to initialise submodules."

    echo
    info "Dotfiles cloned to ${dotfiles_dir}"
    echo "  Host:  ${hostname}"
    echo "  Items: ${items[*]}"
    DOTFILES_DIR="${dotfiles_dir}"
}

main() {
    info "Starting dotfiles bootstrap..."
    echo

    local detected_os
    detected_os="$(detect_os)"

    ensure_dependencies "${detected_os}"
    echo

    setup_prompt_fd
    trap cleanup_prompt_fd EXIT

    clone_dotfiles

    echo
    info "Bootstrap complete! Next steps:"
    echo "  cd ${DOTFILES_DIR:-${DEFAULT_DOTFILES_DIR}}"
    echo "  make dotfiles   # apply symlinks"
    echo "  make install    # install packages"
    echo "  make config     # apply system settings"
}

main "$@"
