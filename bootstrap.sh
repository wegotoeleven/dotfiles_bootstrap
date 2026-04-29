#!/usr/bin/env bash
#
# Automated dotfiles installation with profile-based sparse checkout.
#
# Clones the dotfiles repository, prompts for a machine profile, and performs
# a sparse checkout of only the roles required by that profile.

set -euo pipefail

readonly CONFIG_FILE="${HOME}/.config/machine-profile"
readonly REPO_URL="git@github.com:wegotoeleven/dotfiles.git"
readonly DEFAULT_DOTFILES_DIR="${HOME}/.dotfiles"

# Set by clone_dotfiles(); used in main() for the next-steps message.
DOTFILES_DIR=""

# File descriptor for interactive prompts (0 = stdin, 3 = /dev/tty).
# TTY_FD_OPENED tracks whether we opened /dev/tty so cleanup_prompt_fd()
# can close it.
PROMPT_FD=0
TTY_FD_OPENED=0


# Print an error message to stderr and exit.
fatal() {
    echo "Fatal: ${*}" >&2
    exit 1
}

# Print a progress message to stdout.
info() {
    echo "==> ${*}"
}


# Returns the normalised OS name: "macos", "linux", or "unknown".
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
            sentinel="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
            touch "${sentinel}"

            local pkg
            pkg=$(softwareupdate -l 2>/dev/null \
                | grep '\* Label: Command Line Tools' \
                | sed 's/.*Label: //' \
                | sort | tail -1)

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
#        $2 — prompt string.
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

# Present a numbered menu and return the chosen option on stdout.
# Args: $1 — question string; $2... — menu options.
get_choice() {
    local question="${1}"
    shift
    local options=("$@")

    echo "${question}" >&2
    for i in "${!options[@]}"; do
        echo "$((i + 1))) ${options[$i]}" >&2
    done

    local choice
    while true; do
        prompt_read choice "Choose (1-${#options[@]}): "
        if [[ "${choice}" =~ ^[0-9]+$ ]] \
            && [[ "${choice}" -ge 1 ]] \
            && [[ "${choice}" -le "${#options[@]}" ]]; then
            echo "${options[$((choice - 1))]}"
            return
        fi
        echo "Invalid choice. Please try again." >&2
    done
}


# Sources ~/.config/machine-profile if it exists.
read_config() {
    [[ -f "${CONFIG_FILE}" ]] || return 0
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}" || fatal "Failed to parse ${CONFIG_FILE}."
}

# Returns 0 if MACHINE_PROFILE is set and non-empty.
is_config_complete() {
    [[ -n "${MACHINE_PROFILE:-}" ]]
}

# Warns if the profile's implied OS doesn't match the detected OS.
# Args: $1 — profile name; $2 — OS name as returned by detect_os.
validate_profile_os() {
    local profile="${1}"
    local detected_os="${2}"
    local profile_os=""

    if [[ "${profile}" == *"mac"* ]];   then profile_os="macos"; fi
    if [[ "${profile}" == *"linux"* ]]; then profile_os="linux"; fi

    if [[ -n "${profile_os}" ]] \
        && [[ "${profile_os}" != "${detected_os}" ]]; then
        echo "Warning: profile '${profile}' is for ${profile_os}" \
            "but this machine is ${detected_os}." >&2
        local confirm
        prompt_read confirm "Continue anyway? (y/N): "
        [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
    fi
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

# Clones the dotfiles repo with a sparse checkout of only the required roles.
# Prompts for clone location and (if not already configured) machine profile.
# Sets the DOTFILES_DIR global and changes the working directory on success.
# Args: $1 — OS name as returned by detect_os.
clone_dotfiles() {
    local detected_os="${1}"
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

    info "Cloning dotfiles to ${dotfiles_dir}..."
    git clone --filter=blob:none --no-checkout "${REPO_URL}" "${dotfiles_dir}"
    cd "${dotfiles_dir}" || fatal "Failed to cd to ${dotfiles_dir}."

    # Sparse-checkout profiles/ only so we can read the available profiles.
    info "Fetching available profiles..."
    git sparse-checkout init --cone
    git sparse-checkout set profiles
    git checkout

    local profile
    if is_config_complete; then
        profile="${MACHINE_PROFILE}"
        info "Using existing profile: ${profile}"
        [[ -f "${dotfiles_dir}/profiles/${profile}" ]] \
            || fatal "Existing profile '${profile}' not found in repository."
    else
        local profiles=()
        for f in "${dotfiles_dir}/profiles/"*; do
            [[ -f "${f}" ]] && profiles+=("$(basename "${f}")")
        done

        [[ ${#profiles[@]} -gt 0 ]] || fatal "No profiles found in repository."

        echo
        local question="Select a profile for this machine:"
        profile="$(get_choice "${question}" "${profiles[@]}")"
        validate_profile_os "${profile}" "${detected_os}"

        mkdir -p "$(dirname "${CONFIG_FILE}")"
        echo "MACHINE_PROFILE=${profile}" > "${CONFIG_FILE}"
        info "Configuration saved to ${CONFIG_FILE}."
        export MACHINE_PROFILE="${profile}"
    fi

    # Read the role list from the profile file.
    local roles=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] && roles+=("${line}")
    done < "${dotfiles_dir}/profiles/${profile}"

    # Expand the sparse checkout to include all required roles.
    local sparse_dirs=("profiles" "dotbot")
    for role in "${roles[@]}"; do
        sparse_dirs+=("roles/${role}")
    done

    info "Checking out roles: ${roles[*]}"
    git sparse-checkout set --skip-checks "${sparse_dirs[@]}"
    git checkout
    git submodule update --init --recursive \
        || fatal "Failed to initialise submodules."

    echo
    info "Dotfiles cloned to ${dotfiles_dir}"
    echo "  Profile: ${profile}"
    echo "  Roles:   ${roles[*]}"
    DOTFILES_DIR="${dotfiles_dir}"
}


main() {
    echo "Starting dotfiles bootstrap..."
    echo

    local detected_os
    detected_os="$(detect_os)"

    ensure_dependencies "${detected_os}"
    echo

    setup_prompt_fd
    trap cleanup_prompt_fd EXIT

    read_config
    if is_config_complete; then
        echo "Found existing configuration:"
        echo "  Profile: ${MACHINE_PROFILE}"
        echo
    fi

    clone_dotfiles "${detected_os}"

    echo
    echo "Bootstrap complete! Next steps:"
    echo "  cd ${DOTFILES_DIR:-${DEFAULT_DOTFILES_DIR}}"
    echo "  make dotfiles   # apply symlinks"
    echo "  make install    # install packages"
    echo "  make config     # apply system settings"
}

main "$@"
