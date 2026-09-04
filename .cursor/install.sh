#!/usr/bin/env bash
# Starter environment for the Excalibur builder. Idempotent; safe to re-run.
# The builder may extend this (M0) but should keep it working on a bare Ubuntu image.
set -uo pipefail

log() { echo "[excalibur-install] $*"; }

sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y --no-install-recommends zstd jq curl ca-certificates git xz-utils >/dev/null 2>&1 || log "apt step skipped"

# uv (Python toolchain + tool installs)
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh || log "uv install failed"
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

# Python 3.12 for the controller
uv python install 3.12 >/dev/null 2>&1 || log "uv python install skipped"

# Harbor (evaluator). Pin during M0; latest is acceptable for the first boot.
uv tool install harbor >/dev/null 2>&1 || uv tool upgrade harbor >/dev/null 2>&1 || log "harbor install failed"

# Node 22 via a static tarball (also reused for the sandbox runtime bundle in M1)
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null)" != v22* ]]; then
  NODE_VER="v22.12.0"
  mkdir -p "$HOME/.local/node" && cd "$HOME/.local/node" \
    && curl -fsSLO "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz" \
    && tar -xJf "node-${NODE_VER}-linux-x64.tar.xz" --strip-components=1 \
    && rm -f "node-${NODE_VER}-linux-x64.tar.xz" \
    && cd - >/dev/null || log "node install failed"
  grep -q '.local/node/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.local/node/bin:$PATH"' >> "$HOME/.bashrc"
  export PATH="$HOME/.local/node/bin:$PATH"
fi
command -v corepack >/dev/null 2>&1 && corepack enable >/dev/null 2>&1 || true

# Project deps, if the builder has created pyproject.toml already
if [[ -f pyproject.toml ]]; then uv sync || log "uv sync failed (ok on first boot)"; fi

log "done: uv=$(command -v uv || echo missing) harbor=$(command -v harbor || echo missing) node=$(node -v 2>/dev/null || echo missing)"
