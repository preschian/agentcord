#!/usr/bin/env bash
# Idempotent Cloud Agent setup for the AgentCord landing page (web/).
# macOS (Xcode) and Windows (.NET) trees cannot build on this Linux VM;
# the Astro site in web/ is the runnable development experience here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export BUN_INSTALL="$HOME/.bun"
if [ ! -x "$BUN_INSTALL/bin/bun" ]; then
  curl -fsSL https://bun.sh/install | bash
fi

# Expose bun on PATH for every shell/phase (install runs in the build snapshot).
sudo ln -sf "$BUN_INSTALL/bin/bun" /usr/local/bin/bun

cd web
bun install --frozen-lockfile

echo "bun $(bun --version) ready; web dependencies installed."
