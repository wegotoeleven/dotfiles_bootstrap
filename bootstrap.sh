#!/usr/bin/env bash
# bootstrap.sh
# Automated dotfiles installation with profile-based sparse checkout

set -e  # Exit on error
set -u  # Exit on undefined variable
set -o pipefail  # Exit on pipe failure

# Configuration
readonly CONFIG_FILE="${HOME}/.config/machine-profile"
readonly REPO_URL="git@github.com:wegotoeleven/dotfiles_private.git"
readonly DEFAULT_DOTFILES_DIR="${HOME}/.dotfiles-new"
DOTFILES_DIR=""

# Detect the operating system
detect_os() {
    case "$(uname -s)" in
        Linux*)
            echo "Linux"
            ;;
        Darwin*)
            echo "macOS"
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# Ensure required dependencies are installed
ensure_dependencies() {
    local os="${1}"
    
    if [[ "${os}" == "macOS" ]]; then
        # Check for Xcode Command Line Tools
        if ! xcode-select -p &>/dev/null; then
            echo "Xcode Command Line Tools not found. Installing..."
            xcode-select --install
            
            echo ""
            echo "A dialog should appear. Please click 'Install' and accept the license."
            echo "Waiting for installation to complete..."
            echo ""
            
            # Wait until xcode-select -p succeeds
            until xcode-select -p &>/dev/null; do
                sleep 5
            done
            
            echo "Xcode Command Line Tools installation complete!"
        fi
        
        # Verify git is available
        if ! command -v git &>/dev/null; then
            echo "Error: git not found even after Xcode Command Line Tools check"
            exit 1
        fi
        
        echo "Dependencies verified: git available"
        
    elif [[ "${os}" == "Linux" ]]; then
        # Check for git
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

to_lower() {
    printf '%s' "${1}" | tr '[:upper:]' '[:lower:]'
}

# Present a menu and get user's choice
get_choice() {
    local question="${1}"
    shift
    local options=("$@")

    echo "${question}" >&2
    for i in "${!options[@]}"; do
        echo "$((i + 1))) ${options[$i]}" >&2
    done

    while true; do
        read -rp "Choose (1-${#options[@]}): " choice >&2
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le "${#options[@]}" ]]; then
            echo "${options[$((choice - 1))]}"
            return
        else
            echo "Invalid choice. Please try again." >&2
        fi
    done
}

# Read existing configuration if available
read_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
        return 0
    else
        return 1
    fi
}

# Check if configuration is complete
check_config_complete() {
    [[ -n "${MACHINE_OS:-}" ]] && [[ -n "${MACHINE_TYPE:-}" ]] && [[ -n "${MACHINE_USE:-}" ]]
}

# Setup machine profile configuration
setup_config() {
    local machine_os
    local machine_type
    local machine_use
    
    echo "Setting up machine profile..."

    mkdir -p "$(dirname "${CONFIG_FILE}")"
    machine_os="$(detect_os)"

    echo "Detected OS: ${machine_os}"

    machine_type="$(get_choice "What type of machine is this?" "Server" "Endpoint")"
    machine_use="$(get_choice "What is this machine used for?" "Work" "Personal")"

    cat > "${CONFIG_FILE}" << EOF
MACHINE_OS=${machine_os}
MACHINE_TYPE=${machine_type}
MACHINE_USE=${machine_use}
EOF

    echo "Configuration saved to ${CONFIG_FILE}"
    
    # Export for use in this script
    export MACHINE_OS="${machine_os}"
    export MACHINE_TYPE="${machine_type}"
    export MACHINE_USE="${machine_use}"
}

# Check if directory is safe to use
check_directory() {
    local dir="${1}"

    # Expand tilde to home directory
    dir="${dir/#\~/${HOME}}"

    if [[ -e "${dir}" ]]; then
        if [[ -d "${dir}" ]]; then
            if [[ -n "$(ls -A "${dir}" 2>/dev/null)" ]]; then
                echo "Error: Directory ${dir} already exists and is not empty." >&2
                echo "Please choose a different location or remove the existing directory." >&2
                return 1
            fi
        else
            echo "Error: ${dir} exists but is not a directory." >&2
            return 1
        fi
    fi

    return 0
}

# Clone dotfiles repository with sparse checkout
clone_dotfiles() {
    local machine_os="${1}"
    local machine_type="${2}"
    local machine_use="${3}"
    local dotfiles_dir
    local os_lower
    local type_lower
    local use_lower
    
    # Convert to lowercase for directory names
    os_lower="$(to_lower "${machine_os}")"
    type_lower="$(to_lower "${machine_type}")"
    use_lower="$(to_lower "${machine_use}")"

    while true; do
        read -rp "Where should dotfiles be cloned? [${DEFAULT_DOTFILES_DIR}]: " dotfiles_dir
        dotfiles_dir="${dotfiles_dir:-${DEFAULT_DOTFILES_DIR}}"

        if check_directory "${dotfiles_dir}"; then
            break
        fi
        echo "Please try again."
        echo
    done

    # Expand tilde to home directory
    dotfiles_dir="${dotfiles_dir/#\~/${HOME}}"

    mkdir -p "$(dirname "${dotfiles_dir}")"

    echo "Cloning dotfiles to ${dotfiles_dir}..."

    git clone --filter=blob:none --no-checkout "${REPO_URL}" "${dotfiles_dir}"
    
    cd "${dotfiles_dir}" || {
        echo "Error: Failed to change directory to ${dotfiles_dir}"
        exit 1
    }

    git config core.sparseCheckout true

    declare -a sparse_paths=(
        "bootstrap.sh"
        "README.md"
        "Makefile"
        "dotbot/"
        "common/common/"
        "common/${type_lower}/"
        "common/${use_lower}/"
        "${os_lower}/common/"
        "${os_lower}/${type_lower}/"
        "${os_lower}/${use_lower}/"
    )

    git sparse-checkout init --cone
    git sparse-checkout set "${sparse_paths[@]}"

    git checkout

    git submodule update --init --recursive

    echo "Dotfiles cloned successfully to ${dotfiles_dir}"
    echo "Downloaded configuration for: ${machine_type}-${machine_os}-${machine_use}"
    DOTFILES_DIR="${dotfiles_dir}"
}

# Main execution
main() {
    echo "Starting dotfiles bootstrap..."
    echo

    # Detect OS first
    local detected_os
    detected_os="$(detect_os)"
    
    # Ensure dependencies exist
    ensure_dependencies "${detected_os}"
    
    echo

    # Check for existing configuration
    if read_config && check_config_complete; then
        echo "Found existing configuration:"
        echo "  OS:     ${MACHINE_OS}"
        echo "  Type:   ${MACHINE_TYPE}"
        echo "  Use:    ${MACHINE_USE}"
    else
        echo "Configuration incomplete or missing."
        setup_config
    fi

    echo

    clone_dotfiles "${MACHINE_OS}" "${MACHINE_TYPE}" "${MACHINE_USE}"

    echo
    echo "Bootstrap complete!"
    echo "Next steps:"
    echo "  cd ${DOTFILES_DIR:-${DEFAULT_DOTFILES_DIR}}"
    echo "  make install"
}

main "$@"
