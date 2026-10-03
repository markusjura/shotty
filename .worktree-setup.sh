#!/bin/zsh
# Prepares a new worktree. Codex runs it from .codex/environments/environment.toml; other worktree
# tools can run it too. Worktrees live outside the main checkout, so it asks git where that is.
set -euo pipefail
cd "${0:A:h}"

main_checkout="$(git worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
[[ "$PWD" == "$main_checkout" ]] && exit 0

# The signing team stays untracked. A link keeps every worktree on the main checkout's team.
ln -sfn "$main_checkout/Local.xcconfig" Local.xcconfig
