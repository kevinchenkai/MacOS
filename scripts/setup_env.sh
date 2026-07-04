#!/usr/bin/env bash
# setup_env.sh — Install macOS prerequisites for Claude CLI and OpenAI Codex CLI
# Usage: bash scripts/setup_env.sh

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────
info()    { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()     { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS only."
}

# ── Homebrew ──────────────────────────────────────────────────────────────────
install_homebrew() {
  if command -v brew &>/dev/null; then
    success "Homebrew already installed ($(brew --version | head -1))"
  else
    info "Installing Homebrew…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for Apple Silicon Macs
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    success "Homebrew installed."
  fi
}

# ── Node.js (via nvm) ─────────────────────────────────────────────────────────
install_node() {
  local node_version="lts/iron"   # Node 20 LTS
  if command -v node &>/dev/null; then
    success "Node.js already installed ($(node --version))"
    return
  fi

  if command -v nvm &>/dev/null || [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    info "nvm detected — installing Node.js ${node_version}…"
    # shellcheck source=/dev/null
    source "$HOME/.nvm/nvm.sh"
    nvm install "${node_version}"
    nvm use "${node_version}"
    nvm alias default "${node_version}"
  else
    info "Installing Node.js via Homebrew…"
    brew install node
  fi
  success "Node.js installed ($(node --version))"
}

# ── Python ────────────────────────────────────────────────────────────────────
install_python() {
  if command -v python3 &>/dev/null; then
    local ver
    ver="$(python3 --version 2>&1)"
    success "Python already installed (${ver})"
  else
    info "Installing Python via Homebrew…"
    brew install python
    success "Python installed ($(python3 --version))"
  fi
}

# ── git ───────────────────────────────────────────────────────────────────────
install_git() {
  if command -v git &>/dev/null; then
    success "git already installed ($(git --version))"
  else
    info "Installing git via Homebrew…"
    brew install git
    success "git installed."
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  require_macos
  info "=== macOS environment setup ==="
  install_homebrew
  install_node
  install_python
  install_git
  success "=== Environment setup complete ==="
  info "Next steps:"
  info "  • Run 'bash scripts/install_claude.sh'  to install the Claude CLI"
  info "  • Run 'bash scripts/install_codex.sh'   to install the OpenAI Codex CLI"
}

main "$@"
