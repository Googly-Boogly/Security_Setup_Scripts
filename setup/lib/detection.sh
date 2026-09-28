#!/usr/bin/env bash
# shellcheck disable=SC2034  # library: globals are read by the scripts that source it
# System detection helpers (read-only). Source this file; do not execute it.

[[ -n "${_AIWS_DETECTION_LOADED:-}" ]] && return 0
_AIWS_DETECTION_LOADED=1

# Ubuntu releases these scripts have been written against. Other Ubuntu
# releases may work; non-Ubuntu systems are refused unless explicitly allowed.
SUPPORTED_UBUNTU_VERSIONS=("22.04" "24.04" "26.04")

command_exists() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# Populates OS_ID, OS_VERSION_ID, OS_CODENAME, OS_PRETTY_NAME from os-release.
detect_os() {
  OS_ID="" OS_VERSION_ID="" OS_CODENAME="" OS_PRETTY_NAME=""
  [[ -r /etc/os-release ]] || return 1
  OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
  OS_VERSION_ID="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  OS_CODENAME="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  OS_PRETTY_NAME="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
}

is_ubuntu() { [[ "${OS_ID:-}" == "ubuntu" ]]; }

is_supported_ubuntu() {
  local v
  is_ubuntu || return 1
  for v in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
    [[ "$OS_VERSION_ID" == "$v" ]] && return 0
  done
  return 1
}

os_arch() { dpkg --print-architecture 2>/dev/null || uname -m; }

has_systemd() { [[ -d /run/systemd/system ]]; }

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

# Interface carrying the default IPv4 route (e.g. wlp2s0, enp3s0). Never
# assume eth0: laptops, VMs and USB adapters all name interfaces differently.
default_route_interface() {
  ip -o route show default 2>/dev/null |
    awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

# True when this process descends from sshd. SSH_CONNECTION is not reliable
# here because sudo strips it from the environment.
in_ssh_session() {
  local pid="$$" comm
  [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] && return 0
  while [[ -n "$pid" && "$pid" -gt 1 ]]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    [[ "$comm" == sshd* ]] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  done
  return 1
}

package_installed() {
  local status
  status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  [[ "$status" == "install ok installed" ]]
}

package_available() {
  local candidate
  candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }
unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

user_home() { getent passwd "$1" | cut -d: -f6; }

# Prints the version "major.minor" of the installed OpenSSH, e.g. "9.6".
openssh_version() {
  ssh -V 2>&1 | sed -nE 's/^OpenSSH_([0-9]+\.[0-9]+).*/\1/p'
}

# Running value of a sysctl key. Returns 1 if the kernel lacks the key and
# 2 if it exists but is unreadable (some keys, e.g. bpf_jit_harden, are root-only).
sysctl_value() {
  local path="/proc/sys/${1//./\/}"
  [[ -e "$path" ]] || return 1
  [[ -r "$path" ]] || return 2
  sysctl -n "$1" 2>/dev/null
}

cgroup_v2_enabled() { [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]]; }
