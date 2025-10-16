#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# sys_manager.sh
# Author: Abdul
# Purpose: Modular non-interactive shell script for user & system management
# Usage: ./sys_manager.sh <mode> [args...]
# Modes: add_users, setup_projects, sys_report, process_manage, perm_owner, help
# -----------------------------------------------------------------------------

# -------------------------
# Colors
# -------------------------
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
BOLD="\e[1m"
RESET="\e[0m"

# -------------------------
# Helpers
# -------------------------
err() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()  { echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }

# Check sudo availability for commands that may need it
require_sudo() {
  if [[ $EUID -ne 0 ]]; then
    warn "This operation requires root privileges. 'sudo' will be used where needed."
  fi
}

# Safe exit with code and optional message
safe_exit() {
  local code=${1:-0}
  [[ $code -ne 0 ]] && err "Exiting with status $code"
  exit "$code"
}

# -------------------------
# Mode: add_users (4 marks)
# Usage: ./sys_manager.sh add_users <usernames_file>
# -------------------------
add_users() {
  local file="$1"
  [[ -z "$file" ]] && { err "Usage: $0 add_users <usernames_file>"; safe_exit 1; }
  [[ ! -f "$file" ]] && { err "File not found: $file"; safe_exit 1; }

  require_sudo

  local created=0 already=0
  echo -e "${BOLD}Adding users from file:${RESET} $file"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local user
    user="$(echo "$raw" | awk '{print $1}')"
    [[ -z "$user" ]] && continue
    [[ "$user" =~ ^# ]] && continue   # skip comments

    if id "$user" &>/dev/null; then
      ((already++))
      echo -e "${YELLOW}Already exists:${RESET} $user"
    else
      # create user with home and bash shell
      sudo useradd -m -s /bin/bash "$user" && {
        ((created++))
        echo -e "${GREEN}Created:${RESET} $user"
      } || {
        err "Failed to create user: $user"
      }
    fi
  done < "$file"

  echo
  echo -e "${BOLD}Summary:${RESET}"
  echo -e "${GREEN}Created:${RESET} $created"
  echo -e "${YELLOW}Already existed:${RESET} $already"
  safe_exit 0
}

# -------------------------
# Mode: setup_projects (4 marks)
# Usage: ./sys_manager.sh setup_projects <username> <number_of_projects>
# -------------------------
setup_projects() {
  local username="$1"
  local num="$2"

  [[ -z "$username" || -z "$num" ]] && { err "Usage: $0 setup_projects <username> <number_of_projects>"; safe_exit 1; }
  if ! id "$username" &>/dev/null; then
    err "User does not exist: $username"
    safe_exit 1
  fi
  if ! [[ "$num" =~ ^[0-9]+$ ]] || [[ "$num" -le 0 ]]; then
    err "Number of projects must be a positive integer"
    safe_exit 1
  fi

  require_sudo
  local base="/home/${username}/projects"
  sudo mkdir -p "$base" || { err "Failed to create $base"; safe_exit 1; }

  for ((i=1; i<=num; i++)); do
    local dir="${base}/project${i}"
    sudo mkdir -p "$dir" || { err "Failed to create $dir"; continue; }
    # README with creation date and owner info
    {
      echo "Project: project${i}"
      echo "Created: $(date -R)"
      echo "Owner: ${username}"
    } | sudo tee "${dir}/README.txt" >/dev/null

    # permissions: directories 755, files 640
    sudo find "$dir" -type d -exec chmod 755 {} \;
    sudo find "$dir" -type f -exec chmod 640 {} \;
    sudo chown -R "${username}:${username}" "$dir"
    ok "Created $dir (owner: $username)"
  done

  ok "All projects created under $base"
  safe_exit 0
}

# -------------------------
# Mode: sys_report (3 marks)
# Usage: ./sys_manager.sh sys_report <output_file>
# -------------------------
sys_report() {
  local out="$1"
  [[ -z "$out" ]] && { err "Usage: $0 sys_report <output_file>"; safe_exit 1; }

  {
    echo "==== System report generated: $(date -R) ===="
    echo
    echo "---- DISK USAGE ----"
    df -h
    echo
    echo "---- MEMORY (free -h) ----"
    free -h
    echo
    echo "---- CPU (lscpu) ----"
    lscpu
    echo
    echo "---- Top 5 memory-consuming processes ----"
    ps -eo pid,comm,%mem --sort=-%mem | head -n 6
    echo
    echo "---- Top 5 CPU-consuming processes ----"
    ps -eo pid,comm,%cpu --sort=-%cpu | head -n 6
  } > "$out" 2>/dev/null || { err "Failed to write report to $out"; safe_exit 1; }

  ok "Report saved to $out"
  safe_exit 0
}

# -------------------------
# Mode: process_manage (5 marks)
# Usage: ./sys_manager.sh process_manage <username> <action>
# Actions: list_zombies, list_stopped, kill_zombies, kill_stopped
# -------------------------
process_manage() {
  local user="$1"
  local action="$2"

  [[ -z "$user" || -z "$action" ]] && { err "Usage: $0 process_manage <username> <action>"; safe_exit 1; }
  if ! id "$user" &>/dev/null; then
    err "User not found: $user"; safe_exit 1
  fi

  case "$action" in
    list_zombies)
      echo -e "${BLUE}Zombie processes for user $user:${RESET}"
      # show PID STAT CMD where STAT contains Z
      ps -u "$user" -o pid,stat,cmd --no-headers | awk '$2 ~ /Z/ {print}'
      safe_exit 0
      ;;
    list_stopped)
      echo -e "${BLUE}Stopped processes for user $user:${RESET}"
      ps -u "$user" -o pid,stat,cmd --no-headers | awk '$2 ~ /T/ {print}'
      safe_exit 0
      ;;
    kill_zombies)
      warn "Zombie processes are already dead/in defunct state; cannot be killed directly. Usually fix by killing their parent or reaping by init/systemd."
      echo "Suggested parent PID(s):"
      ps -u "$user" -o pid,ppid,stat,cmd --no-headers | awk '$3 ~ /Z/ {print "PID:"$1, "PPID:"$2, $4}'
      safe_exit 0
      ;;
    kill_stopped)
      warn "Killing stopped processes for $user (will use sudo kill -9 if needed)"
      local pids
      pids=$(ps -u "$user" -o pid,stat --no-headers | awk '$2 ~ /T/ {print $1}')
      if [[ -z "$pids" ]]; then
        ok "No stopped processes found for $user"
        safe_exit 0
      fi
      echo "$pids" | xargs -r sudo kill -9
      ok "Sent SIGKILL to stopped processes: $pids"
      safe_exit 0
      ;;
    *)
      err "Unknown action: $action"
      err "Valid actions: list_zombies, list_stopped, kill_zombies, kill_stopped"
      safe_exit 1
      ;;
  esac
}

# -------------------------
# Mode: perm_owner (4 marks)
# Usage: ./sys_manager.sh perm_owner <username> <path> <permissions> <owner> <group>
# -------------------------
perm_owner() {
  local username="$1"
  local path="$2"
  local perms="$3"
  local owner="$4"
  local group="$5"

  if [[ -z "$username" || -z "$path" || -z "$perms" || -z "$owner" || -z "$group" ]]; then
    err "Usage: $0 perm_owner <username> <path> <permissions> <owner> <group>"
    safe_exit 1
  fi

  if [[ ! -e "$path" ]]; then
    err "Path does not exist: $path"
    safe_exit 1
  fi

  # Validate permission format (e.g., 755)
  if ! [[ "$perms" =~ ^[0-7]{3,4}$ ]]; then
    err "Permissions must be numeric (e.g. 755 or 0644)"
    safe_exit 1
  fi

  require_sudo
  sudo chmod -R "$perms" "$path" || { err "chmod failed on $path"; safe_exit 1; }
  sudo chown -R "${owner}:${group}" "$path" || { err "chown failed on $path"; safe_exit 1; }

  # Verification summary (show top-level)
  echo -e "${BOLD}Verification (top-level):${RESET}"
  ls -ld "$path"
  ok "Permissions and ownership updated for $path"
  safe_exit 0
}

# -------------------------
# Help / Usage (bonus)
# -------------------------
print_help() {
  cat <<EOF
${BOLD}sys_manager.sh${RESET} - Modular system manager script

Usage:
  ./sys_manager.sh add_users <usernames_file>
  ./sys_manager.sh setup_projects <username> <number_of_projects>
  ./sys_manager.sh sys_report <output_file>
  ./sys_manager.sh process_manage <username> <action>
      actions: list_zombies | list_stopped | kill_zombies | kill_stopped
  ./sys_manager.sh perm_owner <username> <path> <permissions> <owner> <group>
  ./sys_manager.sh help

Examples:
  ./sys_manager.sh add_users users.txt
  ./sys_manager.sh setup_projects alice 3
  ./sys_manager.sh sys_report /tmp/sysinfo.txt
  ./sys_manager.sh process_manage bob list_zombies
  ./sys_manager.sh perm_owner alice /home/alice/projects 755 alice alice

Notes:
  - Script is non-interactive; it expects correct args.
  - Commands that require root will use 'sudo'; run as root or have sudo configured.
EOF
  safe_exit 0
}

# -------------------------
# Argument dispatch
# -------------------------
if [[ $# -lt 1 ]]; then
  print_help
fi

mode="$1"
shift

case "$mode" in
  add_users)       add_users "$@" ;;
  setup_projects)  setup_projects "$@" ;;
  sys_report)      sys_report "$@" ;;
  process_manage)  process_manage "$@" ;;
  perm_owner)      perm_owner "$@" ;;
  help)            print_help ;;
  *) err "Unknown mode: $mode"; print_help; safe_exit 1 ;;
esac

