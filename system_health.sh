#!/usr/bin/env bash
#
# system_health.sh
# Menu-driven system utility script for monitoring, user management, file organization, network checks, cron setup, and SSH key setup.
#
# Requirements implemented:
# - menu using case
# - functions for each task
# - loops so menu repeats until exit
# - input validation
# - sudo checks for root-only ops
# - colorized output with ANSI escape codes
# - creates reports saved to files
# - meaningful exit status codes
# - comments explaining logic
#
# Author: generated for you
# Date: 2025-10-16
#

set -o errexit  # exit on most errors
set -o nounset  # treat unset variables as errors
# Not using -o pipefail for portability in very old shells; if available, you can enable it:
# set -o pipefail

# -----------------------
# Colors (ANSI escape codes)
# -----------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# -----------------------
# Global variables
# -----------------------
REPORT_DIR="${PWD}/reports"
SYSTEM_REPORT="${REPORT_DIR}/system_report.txt"
NETWORK_REPORT="${REPORT_DIR}/network_report.txt"
TMP_DIR="$(mktemp -d -t sys_health_XXXX)" || {
  echo -e "${RED}Failed to create temp dir${RESET}"; exit 1;
}

# cleanup on exit
cleanup() {
  rm -rf "${TMP_DIR}" || true
}
trap cleanup EXIT

# -----------------------
# Helper functions
# -----------------------
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }

ensure_report_dir() {
  if [ ! -d "${REPORT_DIR}" ]; then
    mkdir -p "${REPORT_DIR}" || { error "Could not create ${REPORT_DIR}"; exit 1; }
  fi
}

require_command() {
  # usage: require_command dig
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "Command '$1' not found. Install it to enable related features."
    return 1
  fi
  return 0
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

confirm() {
  # simple yes/no prompt
  local prompt="${1:-Are you sure? (y/n): }"
  read -r -p "${prompt}" ans
  case "${ans,,}" in
    y|yes) return 0;;
    *) return 1;;
  esac
}

# -----------------------
# 1) System Health Check
# -----------------------
system_health_check() {
  ensure_report_dir
  info "Collecting system information and saving to ${SYSTEM_REPORT} ..."
  {
    echo "=== Disk usage (df -h) ==="
    df -h
    echo
    echo "=== CPU info (lscpu || /proc/cpuinfo) ==="
    if require_command lscpu; then
      lscpu
    else
      awk -F: '/model name/ {print; exit}' /proc/cpuinfo || true
    fi
    echo
    echo "=== Memory usage (free -h) ==="
    if require_command free; then
      free -h
    else
      cat /proc/meminfo | head -n 20 || true
    fi
    echo
    echo "=== Top processes (top -b -n 1 | head -n 20) ==="
    if require_command top; then
      top -b -n 1 | head -n 20
    fi
  } > "${SYSTEM_REPORT}" 2>&1

  success "System report saved to ${SYSTEM_REPORT}."
  info "Showing first 10 lines of the report:"
  head -n 10 "${SYSTEM_REPORT}" || true
  return 0
}

# -----------------------
# 2) Active Processes
# -----------------------
active_processes() {
  info "Listing all active processes (ps aux)."
  ps aux | less -SR  # preview before filtering; user can quit less with 'q'

  read -r -p "Enter keyword to filter processes (leave empty to skip): " keyword
  if [ -z "${keyword}" ]; then
    warn "No keyword entered; showing all processes again briefly."
    ps aux | head -n 20
    return 0
  fi

  # filter and count; exclude the grep process itself using [k] trick
  matches=$(ps aux | grep -i -- "${keyword}" | grep -v grep || true)
  if [ -z "${matches}" ]; then
    warn "No processes matched keyword '${keyword}'."
    return 0
  fi
  echo "${matches}"
  count=$(echo "${matches}" | wc -l)
  success "Matched processes: ${count}"
  return 0
}

# -----------------------
# 3) User & Group Management
# -----------------------
manage_user_group() {
  # This function will create a user and group, set a default password, and chown a test file.
  read -r -p "Enter new username to create: " newuser
  if [ -z "${newuser}" ]; then
    error "Username cannot be empty."; return 1
  fi

  # validate username format (simple)
  if ! [[ "${newuser}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    error "Invalid username format. Use lowercase letters, digits, dashes, underscores, max 32 chars."
    return 1
  fi

  if id "${newuser}" >/dev/null 2>&1; then
    error "User '${newuser}' already exists."
    return 1
  fi

  if ! is_root; then
    warn "Creating users requires root privileges. This action will use sudo."
  fi

  read -r -p "Enter group name to create and add the user to (default: ${newuser}_grp): " grp
  grp=${grp:-"${newuser}_grp"}

  # create group
  if ! getent group "${grp}" >/dev/null 2>&1; then
    info "Creating group '${grp}' ..."
    sudo groupadd "${grp}" || { error "Failed to create group"; return 1; }
  else
    warn "Group '${grp}' already exists."
  fi

  # create user and add to group
  info "Creating user '${newuser}' and adding to group '${grp}' ..."
  sudo useradd -m -s /bin/bash -g "${grp}" "${newuser}" || { error "useradd failed"; return 1; }

  # set default password (random or provided)
  default_pass="$(tr -dc 'A-Za-z0-9@#$%_- ' < /dev/urandom | head -c12 || echo 'ChangeMe123')"
  echo "${newuser}:${default_pass}" | sudo chpasswd || { error "chpasswd failed"; return 1; }
  success "User '${newuser}' created with default password: ${BOLD}${default_pass}${RESET}"
  warn "Please force user to change password on first login:"
  sudo chage -d 0 "${newuser}" || true

  # Create a test file and change ownership
  testfile="${PWD}/test_file_for_${newuser}.txt"
  echo "This is a test file owned by ${newuser}" > "${testfile}"
  sudo chown "${newuser}:${grp}" "${testfile}" || { error "chown failed"; return 1; }
  success "Test file created and ownership changed: ${testfile}"

  return 0
}

# -----------------------
# 4) File Organizer
# -----------------------
file_organizer() {
  read -r -p "Enter target directory path (absolute or relative): " target_dir
  if [ -z "${target_dir}" ]; then
    error "Directory path cannot be empty."; return 1
  fi

  if [ ! -d "${target_dir}" ]; then
    read -r -p "Directory does not exist. Create it? (y/n): " yn
    case "${yn,,}" in
      y|yes) mkdir -p "${target_dir}" || { error "Failed to create directory"; return 1; } ;;
      *) error "Aborting file organizer."; return 1 ;;
    esac
  fi

  # create subdirectories
  for sub in images docs scripts; do
    mkdir -p "${target_dir}/${sub}" || { error "Failed to create ${sub}"; return 1; }
  done

  info "Moving files..."
  # Move images
  shopt -s nullglob
  mv_cmd() {
    # usage: mv_cmd pattern dest
    local pattern="$1"; local dest="$2"
    local moved=0
    for f in ${target_dir}/${pattern}; do
      # ensure we don't move directories
      if [ -f "${f}" ]; then
        mv -n -- "${f}" "${dest}/" && ((moved++))
      fi
    done
    echo "${moved}"
  }

  moved_images=$(mv_cmd '*.jpg' "${target_dir}/images")
  moved_images_png=$(mv_cmd '*.png' "${target_dir}/images")
  moved_docs_txt=$(mv_cmd '*.txt' "${target_dir}/docs")
  moved_docs_md=$(mv_cmd '*.md' "${target_dir}/docs")
  moved_scripts_sh=$(mv_cmd '*.sh' "${target_dir}/scripts")
  shopt -u nullglob

  success "Moved: jpg=${moved_images}, png=${moved_images_png}, txt=${moved_docs_txt}, md=${moved_docs_md}, sh=${moved_scripts_sh}"

  # show tree if available
  if require_command tree; then
    info "Directory tree for ${target_dir}:"
    tree -a "${target_dir}"
  else
    warn "'tree' not installed. Showing a simple recursive list instead:"
    find "${target_dir}" -maxdepth 3 -print
  fi

  return 0
}

# -----------------------
# 5) Network Diagnostics
# -----------------------
network_diagnostics() {
  ensure_report_dir
  info "Running network diagnostics. Results will be saved to ${NETWORK_REPORT}"
  : > "${NETWORK_REPORT}"

  # ping
  if require_command ping; then
    echo "=== ping -c 3 google.com ===" >> "${NETWORK_REPORT}"
    if ping -c 3 google.com >> "${NETWORK_REPORT}" 2>&1; then
      success "Ping to google.com succeeded."
    else
      warn "Ping to google.com had issues (see ${NETWORK_REPORT})."
    fi
    echo >> "${NETWORK_REPORT}"
  else
    warn "ping command not available."
  fi

  # dig
  if require_command dig; then
    echo "=== dig google.com ===" >> "${NETWORK_REPORT}"
#!/usr/bin/env bash
#
# system_health.sh
# Menu-driven system utility script for monitoring, user management, file organization, network checks, cron setup, and SSH key setup.
#
# Requirements implemented:
# - menu using case
# - functions for each task
# - loops so menu repeats until exit
# - input validation
# - sudo checks for root-only ops
# - colorized output with ANSI escape codes
# - creates reports saved to files
# - meaningful exit status codes
# - comments explaining logic
#
# Author: generated for you
# Date: 2025-10-16
#

set -o errexit  # exit on most errors
set -o nounset  # treat unset variables as errors
# Not using -o pipefail for portability in very old shells; if available, you can enable it:
# set -o pipefail

# -----------------------
# Colors (ANSI escape codes)
# -----------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# -----------------------
# Global variables
# -----------------------
REPORT_DIR="${PWD}/reports"
SYSTEM_REPORT="${REPORT_DIR}/system_report.txt"
NETWORK_REPORT="${REPORT_DIR}/network_report.txt"
TMP_DIR="$(mktemp -d -t sys_health_XXXX)" || {
  echo -e "${RED}Failed to create temp dir${RESET}"; exit 1;
}

# cleanup on exit
cleanup() {
  rm -rf "${TMP_DIR}" || true
}
trap cleanup EXIT

# -----------------------
# Helper functions
# -----------------------
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }

ensure_report_dir() {
  if [ ! -d "${REPORT_DIR}" ]; then
    mkdir -p "${REPORT_DIR}" || { error "Could not create ${REPORT_DIR}"; exit 1; }
  fi
}

require_command() {
  # usage: require_command dig
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "Command '$1' not found. Install it to enable related features."
    return 1
  fi
  return 0
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

confirm() {
  # simple yes/no prompt
  local prompt="${1:-Are you sure? (y/n): }"
  read -r -p "${prompt}" ans
  case "${ans,,}" in
    y|yes) return 0;;
    *) return 1;;
  esac
}

# -----------------------
# 1) System Health Check
# -----------------------
system_health_check() {
  ensure_report_dir
  info "Collecting system information and saving to ${SYSTEM_REPORT} ..."
  {
    echo "=== Disk usage (df -h) ==="
    df -h
    echo
    echo "=== CPU info (lscpu || /proc/cpuinfo) ==="
    if require_command lscpu; then
      lscpu
    else
      awk -F: '/model name/ {print; exit}' /proc/cpuinfo || true
    fi
    echo
    echo "=== Memory usage (free -h) ==="
    if require_command free; then
      free -h
    else
      cat /proc/meminfo | head -n 20 || true
    fi
    echo
    echo "=== Top processes (top -b -n 1 | head -n 20) ==="
    if require_command top; then
      top -b -n 1 | head -n 20
    fi
  } > "${SYSTEM_REPORT}" 2>&1

  success "System report saved to ${SYSTEM_REPORT}."
  info "Showing first 10 lines of the report:"
  head -n 10 "${SYSTEM_REPORT}" || true
  return 0
}

# -----------------------
# 2) Active Processes
# -----------------------
active_processes() {
  info "Listing all active processes (ps aux)."
  ps aux | less -SR  # preview before filtering; user can quit less with 'q'

  read -r -p "Enter keyword to filter processes (leave empty to skip): " keyword
  if [ -z "${keyword}" ]; then
    warn "No keyword entered; showing all processes again briefly."
    ps aux | head -n 20
    return 0
  fi

  # filter and count; exclude the grep process itself using [k] trick
  matches=$(ps aux | grep -i -- "${keyword}" | grep -v grep || true)
  if [ -z "${matches}" ]; then
    warn "No processes matched keyword '${keyword}'."
    return 0
  fi
  echo "${matches}"
  count=$(echo "${matches}" | wc -l)
  success "Matched processes: ${count}"
  return 0
}

# -----------------------
# 3) User & Group Management
# -----------------------
manage_user_group() {
  # This function will create a user and group, set a default password, and chown a test file.
  read -r -p "Enter new username to create: " newuser
  if [ -z "${newuser}" ]; then
    error "Username cannot be empty."; return 1
  fi

  # validate username format (simple)
  if ! [[ "${newuser}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    error "Invalid username format. Use lowercase letters, digits, dashes, underscores, max 32 chars."
    return 1
  fi

  if id "${newuser}" >/dev/null 2>&1; then
    error "User '${newuser}' already exists."
    return 1
  fi

  if ! is_root; then
    warn "Creating users requires root privileges. This action will use sudo."
  fi

  read -r -p "Enter group name to create and add the user to (default: ${newuser}_grp): " grp
  grp=${grp:-"${newuser}_grp"}

  # create group
  if ! getent group "${grp}" >/dev/null 2>&1; then
    info "Creating group '${grp}' ..."
    sudo groupadd "${grp}" || { error "Failed to create group"; return 1; }
  else
    warn "Group '${grp}' already exists."
  fi

  # create user and add to group
  info "Creating user '${newuser}' and adding to group '${grp}' ..."
  sudo useradd -m -s /bin/bash -g "${grp}" "${newuser}" || { error "useradd failed"; return 1; }

  # set default password (random or provided)
  default_pass="$(tr -dc 'A-Za-z0-9@#$%_- ' < /dev/urandom | head -c12 || echo 'ChangeMe123')"
  echo "${newuser}:${default_pass}" | sudo chpasswd || { error "chpasswd failed"; return 1; }
  success "User '${newuser}' created with default password: ${BOLD}${default_pass}${RESET}"
  warn "Please force user to change password on first login:"
  sudo chage -d 0 "${newuser}" || true

  # Create a test file and change ownership
  testfile="${PWD}/test_file_for_${newuser}.txt"
  echo "This is a test file owned by ${newuser}" > "${testfile}"
  sudo chown "${newuser}:${grp}" "${testfile}" || { error "chown failed"; return 1; }
  success "Test file created and ownership changed: ${testfile}"

  return 0
}

# -----------------------
# 4) File Organizer
# -----------------------
file_organizer() {
  read -r -p "Enter target directory path (absolute or relative): " target_dir
  if [ -z "${target_dir}" ]; then
    error "Directory path cannot be empty."; return 1
  fi

  if [ ! -d "${target_dir}" ]; then
    read -r -p "Directory does not exist. Create it? (y/n): " yn
    case "${yn,,}" in
      y|yes) mkdir -p "${target_dir}" || { error "Failed to create directory"; return 1; } ;;
      *) error "Aborting file organizer."; return 1 ;;
    esac
  fi

  # create subdirectories
  for sub in images docs scripts; do
    mkdir -p "${target_dir}/${sub}" || { error "Failed to create ${sub}"; return 1; }
  done

  info "Moving files..."
  # Move images
  shopt -s nullglob
  mv_cmd() {
    # usage: mv_cmd pattern dest
    local pattern="$1"; local dest="$2"
    local moved=0
    for f in ${target_dir}/${pattern}; do
      # ensure we don't move directories
      if [ -f "${f}" ]; then
        mv -n -- "${f}" "${dest}/" && ((moved++))
      fi
    done
    echo "${moved}"
  }

  moved_images=$(mv_cmd '*.jpg' "${target_dir}/images")
  moved_images_png=$(mv_cmd '*.png' "${target_dir}/images")
  moved_docs_txt=$(mv_cmd '*.txt' "${target_dir}/docs")
  moved_docs_md=$(mv_cmd '*.md' "${target_dir}/docs")
  moved_scripts_sh=$(mv_cmd '*.sh' "${target_dir}/scripts")
  shopt -u nullglob

  success "Moved: jpg=${moved_images}, png=${moved_images_png}, txt=${moved_docs_txt}, md=${moved_docs_md}, sh=${moved_scripts_sh}"

  # show tree if available
  if require_command tree; then
    info "Directory tree for ${target_dir}:"
    tree -a "${target_dir}"
  else
    warn "'tree' not installed. Showing a simple recursive list instead:"
    find "${target_dir}" -maxdepth 3 -print
  fi

  return 0
}

# -----------------------
# 5) Network Diagnostics
# -----------------------
network_diagnostics() {
  ensure_report_dir
  info "Running network diagnostics. Results will be saved to ${NETWORK_REPORT}"
  : > "${NETWORK_REPORT}"

  # ping
  if require_command ping; then
    echo "=== ping -c 3 google.com ===" >> "${NETWORK_REPORT}"
    if ping -c 3 google.com >> "${NETWORK_REPORT}" 2>&1; then
      success "Ping to google.com succeeded."
    else
      warn "Ping to google.com had issues (see ${NETWORK_REPORT})."
    fi
    echo >> "${NETWORK_REPORT}"
  else
    warn "ping command not available."
  fi

  # dig
  if require_command dig; then
    echo "=== dig google.com ===" >> "${NETWORK_REPORT}"
    dig google.com +short >> "${NETWORK_REPORT}" 2>&1 || true
    echo >> "${NETWORK_REPORT}"
  else
    warn "dig not available; install 'dnsutils' or 'bind-utils' depending on your distro for dig."
  fi

  # curl headers
  if require_command curl; then
    echo "=== curl -I https://example.com ===" >> "${NETWORK_REPORT}"
    curl -I --silent --max-time 10 https://example.com >> "${NETWORK_REPORT}" 2>&1 || true
    echo >> "${NETWORK_REPORT}"
  else
    warn "curl not available."
  fi

  success "Network diagnostics saved to ${NETWORK_REPORT}."
  info "Tail of the network report:"
  tail -n 20 "${NETWORK_REPORT}" || true

  return 0
}

# -----------------------
# 6) Scheduled Task Setup (cron)
# -----------------------
schedule_cron() {
  read -r -p "Enter absolute path to the script to schedule: " script_path
  if [ -z "${script_path}" ] || [ ! -f "${script_path}" ]; then
    error "Script path is empty or not a file. Aborting."
    return 1
  fi

  read -r -p "Enter minute (0-59): " minute
  read -r -p "Enter hour (0-23): " hour

  # basic validation
  if ! [[ "${minute}" =~ ^[0-9]+$ ]] || [ "${minute}" -lt 0 ] || [ "${minute}" -gt 59 ]; then
    error "Invalid minute. Enter a number 0-59."
    return 1
  fi
  if ! [[ "${hour}" =~ ^[0-9]+$ ]] || [ "${hour}" -lt 0 ] || [ "${hour}" -gt 23 ]; then
    error "Invalid hour. Enter a number 0-23."
    return 1
  fi

  cron_expr="${minute} ${hour} * * * ${script_path} >/dev/null 2>&1"
  info "Cron entry to add: ${cron_expr}"
  # add to current user's crontab safely
  (crontab -l 2>/dev/null | grep -v -F "${script_path}" || true; echo "${cron_expr}") | crontab -
  success "Cron job added for $(whoami) to run ${script_path} at ${hour}:${minute} daily."
  return 0
}

# -----------------------
# 7) SSH Key Setup
# -----------------------
ssh_key_setup() {
  key_file_default="${HOME}/.ssh/id_rsa_system_health"
  read -r -p "Enter key path (default: ${key_file_default}): " key_path
  key_path=${key_path:-"${key_file_default}"}

  if [ -f "${key_path}" ] || [ -f "${key_path}.pub" ]; then
    warn "Key file ${key_path} or ${key_path}.pub already exists."
    read -r -p "Overwrite? (y/n): " yn
    case "${yn,,}" in
      y|yes) rm -f "${key_path}" "${key_path}.pub" ;;
      *) info "Aborting key generation."; return 1 ;;
    esac
  fi

  # generate key without passphrase (ask user if they want a passphrase)
  read -r -p "Enter passphrase for the key (leave empty for no passphrase): " passphrase
  # run ssh-keygen
  if require_command ssh-keygen; then
    if [ -z "${passphrase}" ]; then
      ssh-keygen -t rsa -b 4096 -f "${key_path}" -N "" || { error "ssh-keygen failed"; return 1; }
    else
      ssh-keygen -t rsa -b 4096 -f "${key_path}" -N "${passphrase}" || { error "ssh-keygen failed"; return 1; }
    fi
    success "SSH key generated at ${key_path} (public key: ${key_path}.pub)."
    echo
    info "Public key:"
    echo "-----------------"
    cat "${key_path}.pub"
    echo "-----------------"
    echo
    info "To copy it to a remote server, run:"
    echo -e "${BOLD}ssh-copy-id -i ${key_path}.pub user@remote-host${RESET}"
    echo "Or, manually append the public key to ~/.ssh/authorized_keys on the remote server."
    return 0
  else
    error "ssh-keygen not available. Install openssh-client or equivalent."
    return 1
  fi
}

# -----------------------
# 8) Exit
# -----------------------
exit_script() {
  success "Goodbye!"
  exit 0
}

# -----------------------
# Menu loop & selection
# -----------------------
show_menu() {
  cat <<-MENU
${BOLD}${MAGENTA}System Health Menu${RESET}
${CYAN}1) System Health Check${RESET}
${CYAN}2) Active Processes${RESET}
${CYAN}3) User & Group Management${RESET}
${CYAN}4) File Organizer${RESET}
${CYAN}5) Network Diagnostics${RESET}
${CYAN}6) Scheduled Task Setup (cron)${RESET}
${CYAN}7) SSH Key Setup${RESET}
${CYAN}8) Exit${RESET}
MENU
}

main_loop() {
  while true; do
    show_menu
    read -r -p "Choose an option [1-8]: " choice
    case "${choice}" in
      1) system_health_check || warn "system_health_check failed with $?";;
      2) active_processes || warn "active_processes failed with $?";;
      3) manage_user_group || warn "manage_user_group failed with $?";;
      4) file_organizer || warn "file_organizer failed with $?";;
      5) network_diagnostics || warn "network_diagnostics failed with $?";;
      6) schedule_cron || warn "schedule_cron failed with $?";;
      7) ssh_key_setup || warn "ssh_key_setup failed with $?";;
      8) exit_script;;
      *) warn "Invalid option: ${choice}. Please choose 1-8.";;
    esac
    echo
    read -r -p "Press Enter to return to menu..."
    clear
  done
}

# If this script is being sourced, don't run the loop
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_loop
fi
    dig google.com +short >> "${NETWORK_REPORT}" 2>&1 || true
    echo >> "${NETWORK_REPORT}"
  else
    warn "dig not available; install 'dnsutils' or 'bind-utils' depending on your distro for dig."
  fi

  # curl headers
  if require_command curl; then
    echo "=== curl -I https://example.com ===" >> "${NETWORK_REPORT}"
    curl -I --silent --max-time 10 https://example.com >> "${NETWORK_REPORT}" 2>&1 || true
    echo >> "${NETWORK_REPORT}"
  else
    warn "curl not available."
  fi

  success "Network diagnostics saved to ${NETWORK_REPORT}."
  info "Tail of the network report:"
  tail -n 20 "${NETWORK_REPORT}" || true

  return 0
}

# -----------------------
# 6) Scheduled Task Setup (cron)
# -----------------------
schedule_cron() {
  read -r -p "Enter absolute path to the script to schedule: " script_path
  if [ -z "${script_path}" ] || [ ! -f "${script_path}" ]; then
    error "Script path is empty or not a file. Aborting."
    return 1
  fi

  read -r -p "Enter minute (0-59): " minute
  read -r -p "Enter hour (0-23): " hour

  # basic validation
  if ! [[ "${minute}" =~ ^[0-9]+$ ]] || [ "${minute}" -lt 0 ] || [ "${minute}" -gt 59 ]; then
    error "Invalid minute. Enter a number 0-59."
    return 1
  fi
  if ! [[ "${hour}" =~ ^[0-9]+$ ]] || [ "${hour}" -lt 0 ] || [ "${hour}" -gt 23 ]; then
    error "Invalid hour. Enter a number 0-23."
    return 1
  fi

  cron_expr="${minute} ${hour} * * * ${script_path} >/dev/null 2>&1"
  info "Cron entry to add: ${cron_expr}"
  # add to current user's crontab safely
  (crontab -l 2>/dev/null | grep -v -F "${script_path}" || true; echo "${cron_expr}") | crontab -
  success "Cron job added for $(whoami) to run ${script_path} at ${hour}:${minute} daily."
  return 0
}

# -----------------------
# 7) SSH Key Setup
# -----------------------
ssh_key_setup() {
  key_file_default="${HOME}/.ssh/id_rsa_system_health"
  read -r -p "Enter key path (default: ${key_file_default}): " key_path
  key_path=${key_path:-"${key_file_default}"}

  if [ -f "${key_path}" ] || [ -f "${key_path}.pub" ]; then
    warn "Key file ${key_path} or ${key_path}.pub already exists."
    read -r -p "Overwrite? (y/n): " yn
    case "${yn,,}" in
      y|yes) rm -f "${key_path}" "${key_path}.pub" ;;
      *) info "Aborting key generation."; return 1 ;;
    esac
  fi

  # generate key without passphrase (ask user if they want a passphrase)
  read -r -p "Enter passphrase for the key (leave empty for no passphrase): " passphrase
  # run ssh-keygen
  if require_command ssh-keygen; then
    if [ -z "${passphrase}" ]; then
      ssh-keygen -t rsa -b 4096 -f "${key_path}" -N "" || { error "ssh-keygen failed"; return 1; }
    else
      ssh-keygen -t rsa -b 4096 -f "${key_path}" -N "${passphrase}" || { error "ssh-keygen failed"; return 1; }
    fi
    success "SSH key generated at ${key_path} (public key: ${key_path}.pub)."
    echo
    info "Public key:"
    echo "-----------------"
    cat "${key_path}.pub"
    echo "-----------------"
    echo
    info "To copy it to a remote server, run:"
    echo -e "${BOLD}ssh-copy-id -i ${key_path}.pub user@remote-host${RESET}"
    echo "Or, manually append the public key to ~/.ssh/authorized_keys on the remote server."
    return 0
  else
    error "ssh-keygen not available. Install openssh-client or equivalent."
    return 1
  fi
}

# -----------------------
# 8) Exit
# -----------------------
exit_script() {
  success "Goodbye!"
  exit 0
}

# -----------------------
# Menu loop & selection
# -----------------------
show_menu() {
  cat <<-MENU
${BOLD}${MAGENTA}System Health Menu${RESET}
${CYAN}1) System Health Check${RESET}
${CYAN}2) Active Processes${RESET}
${CYAN}3) User & Group Management${RESET}
${CYAN}4) File Organizer${RESET}
${CYAN}5) Network Diagnostics${RESET}
${CYAN}6) Scheduled Task Setup (cron)${RESET}
${CYAN}7) SSH Key Setup${RESET}
${CYAN}8) Exit${RESET}
MENU
}

main_loop() {
  while true; do
    show_menu
    read -r -p "Choose an option [1-8]: " choice
    case "${choice}" in
      1) system_health_check || warn "system_health_check failed with $?";;
      2) active_processes || warn "active_processes failed with $?";;
      3) manage_user_group || warn "manage_user_group failed with $?";;
      4) file_organizer || warn "file_organizer failed with $?";;
      5) network_diagnostics || warn "network_diagnostics failed with $?";;
      6) schedule_cron || warn "schedule_cron failed with $?";;
      7) ssh_key_setup || warn "ssh_key_setup failed with $?";;
      8) exit_script;;
      *) warn "Invalid option: ${choice}. Please choose 1-8.";;
    esac
    echo
    read -r -p "Press Enter to return to menu..."
    clear
  done
}

# If this script is being sourced, don't run the loop
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_loop
fi
