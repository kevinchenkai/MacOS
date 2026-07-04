#!/usr/bin/env bash
# install_claude.sh — Install and configure Anthropic's Claude CLI on macOS
# Usage: bash scripts/install_claude.sh
#
# The Claude CLI is available as the '@anthropic-ai/claude-code' npm package.
# Docs: https://docs.anthropic.com/en/docs/claude-code

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────
info()    { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()     { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS only."
}

require_node() {
  command -v node &>/dev/null || die "Node.js is required. Run 'bash scripts/setup_env.sh' first."
  command -v npm  &>/dev/null || die "npm is required. Run 'bash scripts/setup_env.sh' first."
}

# ── install ───────────────────────────────────────────────────────────────────
install_claude_cli() {
  info "Installing @anthropic-ai/claude-code globally…"
  npm install -g @anthropic-ai/claude-code
  # Ensure the npm global bin directory is on PATH for the current shell
  local npm_bin
  npm_bin="$(npm bin -g 2>/dev/null || npm prefix -g)/bin"
  export PATH="${npm_bin}:${PATH}"
  local version
  version="$(claude --version 2>/dev/null || true)"
  success "Claude CLI installed${version:+ (${version})}"
}

# ── configure ─────────────────────────────────────────────────────────────────
configure_api_key() {
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    success "ANTHROPIC_API_KEY is already set in the current environment."
    return
  fi

  local key_file="$HOME/.config/claude/api_key"
  if [[ -f "$key_file" ]] && grep -qE '^sk-ant-' "$key_file" 2>/dev/null; then
    success "API key already stored in ${key_file}."
    return
  fi

  warn "No ANTHROPIC_API_KEY environment variable found."
  info  "You can obtain an API key from https://console.anthropic.com/settings/keys"
  printf 'Enter your Anthropic API key (sk-ant-…): '
  read -r api_key

  if [[ -z "$api_key" ]]; then
    warn "No key entered — skipping API key configuration."
    warn "Set ANTHROPIC_API_KEY in your shell profile before using the Claude CLI."
    return
  fi

  mkdir -p "$(dirname "$key_file")"
  printf '%s\n' "$api_key" > "$key_file"
  chmod 600 "$key_file"
  success "API key saved to ${key_file}"

  # Append export to shell profile if not already present
  local shell_profile
  if [[ "${SHELL:-}" == */zsh ]]; then
    shell_profile="$HOME/.zshrc"
  elif [[ "${SHELL:-}" == */bash ]]; then
    shell_profile="$HOME/.bash_profile"
  fi

  if [[ -n "${shell_profile:-}" ]]; then
    local export_line="export ANTHROPIC_API_KEY=\"\$(cat ${key_file})\""
    if ! grep -qF "$export_line" "$shell_profile" 2>/dev/null; then
      printf '\n# Claude CLI\n%s\n' "$export_line" >> "$shell_profile"
      success "Added ANTHROPIC_API_KEY export to ${shell_profile}"
    fi
  fi
}

# ── verify ────────────────────────────────────────────────────────────────────
verify_installation() {
  if command -v claude &>/dev/null; then
    success "Claude CLI is available at: $(command -v claude)"
  else
    die "Claude CLI not found in PATH after installation. Check your npm global bin path."
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  require_macos
  require_node
  info "=== Claude CLI installation ==="
  install_claude_cli
  configure_api_key
  verify_installation
  success "=== Claude CLI ready ==="
  info "Run 'claude --help' to get started."
}

main "$@"
