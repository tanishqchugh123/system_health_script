#!/usr/bin/env bash
# Simple system manager script

# -------------------------
# Helpers
# -------------------------
err() { echo "[ERROR] $*"; }
ok()  { echo "[OK] $*"; }

safe_exit() { exit "$1"; }

# -------------------------
# Add users from file
# -------------------------
add_users() {
  file="$1"
  [[ ! -f "$file" ]] && { err "File not found"; safe_exit 1; }
  while read -r user; do
    [[ -z "$user" || "$user" =~ ^# ]] && continue
    if ! id "$user" &>/dev/null; then
    sudo useradd -m -s /bin/bash "$user" && ok "Created $user"
fi
  done < "$file"
}

# -------------------------
# Setup projects for user
# -------------------------
setup_projects() {
  user="$1"; num="$2"
  [[ ! $(id -u "$user" 2>/dev/null) ]] && { err "User not found"; safe_exit 1; }
  base="/home/$user/projects"
  sudo mkdir -p "$base"
  for i in $(seq 1 "$num"); do
    dir="$base/project$i"
    sudo mkdir -p "$dir"
    echo -e "Project: project$i\nOwner: $user\nCreated: $(date)" | sudo tee "$dir/README.txt" >/dev/null
    sudo chown -R "$user:$user" "$dir"
    ok "Created $dir"
  done
}

# -------------------------
# System report
# -------------------------
sys_report() {
  out="$1"
  {
    echo "System report: $(date)"
    df -h
    free -h
    lscpu
    echo "Top memory processes:"; ps -eo pid,comm,%mem --sort=-%mem | head -6
    echo "Top CPU processes:"; ps -eo pid,comm,%cpu --sort=-%cpu | head -6
  } > "$out"
  ok "Report saved to $out"
}

# -------------------------
# Manage processes
# -------------------------
process_manage() {
  user="$1"; action="$2"
  case "$action" in
    list_zombies) ps -u "$user" -o pid,stat,cmd | awk '$2 ~ /Z/' ;;
    list_stopped) ps -u "$user" -o pid,stat,cmd | awk '$2 ~ /T/' ;;
    kill_stopped)
      pids=$(ps -u "$user" -o pid,stat | awk '$2 ~ /T/ {print $1}')
      [[ -n "$pids" ]] && echo "$pids" | xargs sudo kill -9
      ;;
    *) err "Unknown action"; safe_exit 1 ;;
  esac
}

# -------------------------
# Set permissions & owner
# -------------------------
perm_owner() {
  path="$2"; perms="$3"; owner="$4"; group="$5"
  [[ ! -e "$path" ]] && { err "Path not found"; safe_exit 1; }
  sudo chmod -R "$perms" "$path"
  sudo chown -R "$owner:$group" "$path"
  ok "Updated $path"
}

# -------------------------
# Help
# -------------------------
help() {
  echo "Usage: $0 <mode> [args]"
  echo "Modes: add_users <file>, setup_projects <user> <num>, sys_report <file>, process_manage <user> <action>, perm_owner <user> <path> <perms> <owner> <group>"
  safe_exit 0
}

# -------------------------
# Main
# -------------------------
[[ $# -lt 1 ]] && help
mode="$1"; shift
case "$mode" in
  add_users) add_users "$@" ;;
  setup_projects) setup_projects "$@" ;;
  sys_report) sys_report "$@" ;;
  process_manage) process_manage "$@" ;;
  perm_owner) perm_owner "$@" ;;
  help) help ;;
  *) err "Unknown mode"; help ;;
esac
