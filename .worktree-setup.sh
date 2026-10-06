#!/bin/zsh
# Prepares a new worktree. Codex runs it from .codex/environments/environment.toml; other worktree
# tools can run it too. Worktrees live outside the main checkout, so it asks git where that is.
set -euo pipefail
cd "${0:A:h}"

main_checkout="$(git worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
[[ "$PWD" == "$main_checkout" ]] && exit 0

# Base new worktrees on origin/main, never on local main, which may hold unpushed work. Only a clean,
# detached HEAD with no commits of its own moves, so branch starts and carried-over changes stay put.
git fetch --quiet origin main || print -u2 "worktree-setup: fetch failed, using the last fetched origin/main"
if ! git symbolic-ref -q HEAD >/dev/null \
  && [[ -z "$(git status --porcelain)" ]] \
  && [[ -z "$(git rev-list HEAD --not --branches --remotes)" ]]; then
  git checkout --quiet --detach origin/main
fi

# The signing team stays untracked. A link keeps every worktree on the main checkout's team.
ln -sfn "$main_checkout/Local.xcconfig" Local.xcconfig
