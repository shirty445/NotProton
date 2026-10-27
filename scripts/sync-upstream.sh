#!/bin/sh
# NotProtonGPTK: pull NotProtonNot/NotProton into this fork, then run the quick checks.
#
#   scripts/sync-upstream.sh            merge upstream/main into the current branch
#   scripts/sync-upstream.sh --build    also build the app (needs Xcode and mingw-w64)
#
# On a conflict the merge is left in progress so it can be resolved by hand; FORK.md lists
# the upstream files this fork changes and what each change is for.
set -eu

UPSTREAM="${UPSTREAM:-https://github.com/NotProtonNot/NotProton.git}"
BRANCH="${UPSTREAM_BRANCH:-main}"

cd "$(git rev-parse --show-toplevel)"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "error: commit or stash your changes first" >&2
  exit 1
fi

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM"
git fetch upstream "$BRANCH"

if git merge-base --is-ancestor "upstream/$BRANCH" HEAD; then
  echo "==> already up to date with upstream/$BRANCH"
else
  if ! git merge --no-edit "upstream/$BRANCH"; then
    echo
    echo "==> the merge stopped on conflicts. Fix the files above, then:"
    echo "      git add <files> && git commit && scripts/sync-upstream.sh"
    exit 1
  fi
  echo "==> merged upstream/$BRANCH"
fi

# The run script edits are the likeliest to drift, and these checks are fast.
sh -n dylib/feats/compat_run.sh
for check in bridgecheck buildcheck seedcheck runcheck; do
  make -s "$check"
done

if [ "${1:-}" = "--build" ]; then
  make all overlay-shim iconmaker appinfo bridge fonts app-payload app
  echo "==> built out/NotProton.app"
fi
