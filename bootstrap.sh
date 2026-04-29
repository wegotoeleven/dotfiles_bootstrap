#!/usr/bin/env bash
# bootstrap.sh
# Automated dotfiles installation with profile-based sparse checkout

set -e          # Exit on error
set -u          # Exit on undefined variable
set -o pipefail # Exit on pipe failure

# Configuration
readonly CONFIG_FILE="${HOME}/.config/machine-profile"
readonly REPO_URL="git@github.com:wegotoeleven/dotfiles.git"
readonly DEFAULT_DOTFILES_DIR="${HOME}/.dotfiles"

DOTFILES_DIR=""
PROMPT_FD=0
TTY_FD_OPENED=0

# Detect the operating system
detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}

# Ensure required dependencies are installed
ensure_dependencies() {
    local os="${1}"

    if [[ "${os}" == "macos" ]]; then
        if ! xcode-select -p &>/dev/null; then
            echo "Xcode Command Line Tools not found. Installing..."

            # Use softwareupdate so this works on headless machines (no GUI popup).
            # The sentinel file causes softwareupdate to surface the CLT package.
            local sentinel="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
            touch "${sentinel}"
            local pkg
            # Extract the label, then normalise to the identifier format softwareupdate -i
            # expects: strip "Label: ", replace the space before the version with a hyphen,
            # and drop any build suffix (e.g. "Xcode 26.4-26.4.1" → "Xcode-26.4").
            pkg=$(softwareupdate -l 2>/dev/null \
                | grep '\* Label: Command Line Tools' \
                | sed 's/.*Label: //' \
                | sed 's/ \([0-9][0-9.]*\).*$/-\1/' \
                | sort | tail -1)
            rm -f "${sentinel}"

            if [[ -z "${pkg}" ]]; then
                echo "Error: Could not find Command Line Tools package via softwareupdate." >&2
                exit 1
            fi

            echo "Installing: ${pkg}"
            sudo softwareupdate -i "${pkg}" --verbose

            if ! xcode-select -p &>/dev/null; then
                echo "Error: Xcode Command Line Tools installation failed." >&2
                exit 1
            fi

            echo "Xcode Command Line Tools installation complete!"
        fi
        if ! command -v git &>/dev/null; then
            echo "Error: git not found even after Xcode Command Line Tools check"
            exit 1
        fi
        echo "Dependencies verified: git available"

    elif [[ "${os}" == "linux" ]]; then
        if ! command -v git &>/dev/null; then
            echo "git not found. Attempting to install..."
            if command -v apt-get &>/dev/null; then
                sudo apt-get update && sudo apt-get install -y git
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y git
            elif command -v yum &>/dev/null; then
                sudo yum install -y git
            else
                echo "Error: Unable to install git automatically."
                echo "Please install git manually and re-run this script."
                exit 1
            fi
        fi
        echo "Dependencies verified: git available"
    fi
}

setup_prompt_fd() {
    if [[ -t 0 ]]; then
        PROMPT_FD=0
    elif [[ -r /dev/tty ]]; then
        exec 3</dev/tty
        PROMPT_FD=3
        TTY_FD_OPENED=1
    else
        echo "Error: No interactive terminal detected; cannot prompt for input." >&2
        exit 1
    fi
}

cleanup_prompt_fd() {
    if [[ "${TTY_FD_OPENED}" -eq 1 ]]; then
        exec 3<&-
    fi
}

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

# Present a numbered menu and return the chosen option
get_choice() {
    local question="${1}"
    shift
    local options=("$@")

    echo "${question}" >&2
    for i in "${!options[@]}"; do
        echo "$((i + 1))) ${options[$i]}" >&2
    done

    while true; do
        prompt_read choice "Choose (1-${#options[@]}): "
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le "${#options[@]}" ]]; then
            echo "${options[$((choice - 1))]}"
            return
        else
            echo "Invalid choice. Please try again." >&2
        fi
    done
}

# Read existing configuration if present
read_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
        return 0
    else
        return 1
    fi
}

check_config_complete() {
    [[ -n "${MACHINE_PROFILE:-}" ]]
}

# Warn if the selected profile's OS doesn't match the detected OS
validate_profile_os() {
    local profile="${1}"
    local detected_os="${2}"
    local profile_os=""

    if [[ "${profile}" == *"mac"* ]]; then
        profile_os="macos"
    elif [[ "${profile}" == *"linux"* ]]; then
        profile_os="linux"
    fi

    if [[ -n "${profile_os}" ]] && [[ "${profile_os}" != "${detected_os}" ]]; then
        echo "Warning: profile '${profile}' is for ${profile_os} but this machine is ${detected_os}." >&2
        prompt_read confirm "Continue anyway? (y/N): "
        [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
    fi
}

# Check if directory is safe to clone into
check_directory() {
    local dir="${1}"
    dir="${dir/#\~/${HOME}}"

    if [[ -e "${dir}" ]]; then
        if [[ -d "${dir}" ]]; then
            if [[ -n "$(ls -A "${dir}" 2>/dev/null)" ]]; then
                echo "Error: ${dir} already exists and is not empty." >&2
                return 1
            fi
        else
            echo "Error: ${dir} exists but is not a directory." >&2
            return 1
        fi
    fi
    return 0
}

# Clone the dotfiles repo with a sparse checkout containing only the needed roles
clone_dotfiles() {
    local detected_os="${1}"
    local dotfiles_dir

    while true; do
        prompt_read dotfiles_dir "Where should dotfiles be cloned? [${DEFAULT_DOTFILES_DIR}]: "
        dotfiles_dir="${dotfiles_dir:-${DEFAULT_DOTFILES_DIR}}"
        if check_directory "${dotfiles_dir}"; then
            break
        fi
        echo "Please try again."
        echo
    done

    dotfiles_dir="${dotfiles_dir/#\~/${HOME}}"
    mkdir -p "$(dirname "${dotfiles_dir}")"

    echo "Cloning dotfiles to ${dotfiles_dir}..."
    git clone --filter=blob:none --no-checkout "${REPO_URL}" "${dotfiles_dir}"

    cd "${dotfiles_dir}" || {
        echo "Error: Failed to change directory to ${dotfiles_dir}"
        exit 1
    }

    # Step 1: sparse-checkout just profiles/ to read available profiles
    echo "Fetching available profiles..."
    git sparse-checkout init --cone
    git sparse-checkout set profiles
    git checkout

    # Step 2: determine which profile to use
    local profile
    if check_config_complete; then
        profile="${MACHINE_PROFILE}"
        echo "Using existing profile: ${profile}"
        if [[ ! -f "${dotfiles_dir}/profiles/${profile}" ]]; then
            echo "Error: Existing profile '${profile}' not found in repository." >&2
            exit 1
        fi
    else
        # Build profile list from what's actually in the repo
        local profiles=()
        for f in "${dotfiles_dir}/profiles/"*; do
            [[ -f "${f}" ]] && profiles+=("$(basename "${f}")")
        done

        if [[ ${#profiles[@]} -eq 0 ]]; then
            echo "Error: No profiles found in repository." >&2
            exit 1
        fi

        echo ""
        profile="$(get_choice "Select a profile for this machine:" "${profiles[@]}")"
        validate_profile_os "${profile}" "${detected_os}"

        mkdir -p "$(dirname "${CONFIG_FILE}")"
        echo "MACHINE_PROFILE=${profile}" > "${CONFIG_FILE}"
        echo "Configuration saved to ${CONFIG_FILE}"
        export MACHINE_PROFILE="${profile}"
    fi

    # Step 3: read the role list from the profile file
    local roles=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] && roles+=("${line}")
    done < "${dotfiles_dir}/profiles/${profile}"

    # Step 4: expand the sparse checkout to include all required roles
    local sparse_dirs=("profiles" "dotbot")
    for role in "${roles[@]}"; do
        sparse_dirs+=("roles/${role}")
    done

    echo "Checking out roles: ${roles[*]}"
    git sparse-checkout set "${sparse_dirs[@]}"
    git checkout

    git submodule update --init --recursive

    echo ""
    echo "Dotfiles cloned to ${dotfiles_dir}"
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

    if read_config && check_config_complete; then
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
