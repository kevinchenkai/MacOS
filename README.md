# MacOS Scripts

Shell scripts for setting up and using **Anthropic Claude CLI** and **OpenAI Codex CLI** on macOS.

## Scripts

| Script | Description |
|--------|-------------|
| `scripts/setup_env.sh` | Install Homebrew, Node.js, Python, and git prerequisites |
| `scripts/install_claude.sh` | Install `@anthropic-ai/claude-code` and configure your Anthropic API key |
| `scripts/install_codex.sh` | Install `@openai/codex` and configure your OpenAI API key |

## Quick start

```bash
# 1. Install prerequisites (Homebrew, Node.js, Python, git)
bash scripts/setup_env.sh

# 2a. Install the Claude CLI
bash scripts/install_claude.sh

# 2b. Install the Codex CLI
bash scripts/install_codex.sh
```

## Requirements

- macOS 12 Monterey or later
- Internet connection (packages are downloaded during installation)

## API keys

| Tool | Where to get a key |
|------|--------------------|
| Claude CLI | <https://console.anthropic.com/settings/keys> |
| Codex CLI  | <https://platform.openai.com/api-keys> |

Each install script will prompt for your API key and persist it to
`~/.config/<tool>/api_key`, then add the matching `export` line to your
`~/.zshrc` (or `~/.bash_profile`).

You can also supply the key as an environment variable before running a script:

```bash
ANTHROPIC_API_KEY=sk-ant-… bash scripts/install_claude.sh
OPENAI_API_KEY=sk-…        bash scripts/install_codex.sh
```

## Usage

```bash
# Claude
claude "Explain this file" < myfile.py

# Codex
codex "Write a bash function that…"
```

Refer to the official documentation for full usage details:

- Claude CLI: <https://docs.anthropic.com/en/docs/claude-code>
- Codex CLI: <https://github.com/openai/codex>
