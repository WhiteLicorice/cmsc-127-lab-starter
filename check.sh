#!/usr/bin/env bash
set -euo pipefail

runner_tag="v1.10"
runner_url="https://github.com/WhiteLicorice/cmsc-127-harness.git"
cache_root="${CMSC127_RUNNER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cmsc127-runner}"
runner_dir="$cache_root/$runner_tag"

if [[ -n "${CMSC127_RUNNER_DIR:-}" ]]; then
  runner_dir="$CMSC127_RUNNER_DIR"
  if [[ ! -f "$runner_dir/runner.py" ]]; then
    printf 'The local runner directory has no runner.py: %s\n' "$runner_dir" >&2
    exit 1
  fi
else
  mkdir -p "$runner_dir"

  if [[ ! -f "$runner_dir/runner.py" ]]; then
    git -C "$runner_dir" init --quiet
    git -C "$runner_dir" remote remove origin >/dev/null 2>&1 || true
    git -C "$runner_dir" remote add origin "$runner_url"
    if ! git -C "$runner_dir" fetch --quiet --depth 1 origin "refs/tags/$runner_tag:refs/tags/$runner_tag" 2>/dev/null; then
      printf 'Could not fetch pinned runner tag %s. Check the network and try again.\n' "$runner_tag" >&2
      exit 1
    fi
    if ! git -C "$runner_dir" checkout --quiet --detach "refs/tags/$runner_tag"; then
      printf 'Could not select pinned runner tag %s. Check the local cache.\n' "$runner_tag" >&2
      exit 1
    fi
  fi

  if [[ "$(git -C "$runner_dir" describe --tags --exact-match HEAD 2>/dev/null || true)" != "$runner_tag" ]]; then
    printf 'The local runner cache does not match pinned tag %s. Remove only %s and try again.\n' "$runner_tag" "$runner_dir" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$runner_dir" status --porcelain --untracked-files=all)" ]]; then
    printf 'The local runner cache has changed files. Remove only %s and try again.\n' "$runner_dir" >&2
    exit 1
  fi
fi

if [[ " $* " == *" --self-test "* && ! -f "$runner_dir/public/app.js" ]]; then
  if ! command -v npm >/dev/null 2>&1; then
    printf 'The self-test needs Node.js and npm to build the page assets.\n' >&2
    exit 1
  fi
  ( cd "$runner_dir" && npm ci && npm run build )
fi

export PYTHONDONTWRITEBYTECODE=1
exec python "$runner_dir/runner.py" "$@"
