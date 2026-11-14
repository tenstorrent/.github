#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# After a not-ready fallback in a job with an existing cachew session, the
# official checkout ran against a throwaway copy of the job's global Git file
# (CACHEW_FALLBACK_CONFIG, written by prepare.sh). Point the job back at the
# real file, keeping the safe.directory entries the checkout added, as the
# configure step does for a ready session. Needs only Git.
set -u

directory=${CACHEW_SESSION_DIR:-}
fallback=${CACHEW_FALLBACK_CONFIG:-}
[ -n "$directory" ] && [ -f "$directory/global.config" ] || exit 0
global=$directory/global.config

if [ -n "$fallback" ] && [ -f "$fallback" ]; then
  existing=$(git config --file "$global" --null --get-all safe.directory 2>/dev/null | tr '\0' '\n')
  while IFS= read -r -d '' value; do
    [ -n "$value" ] || continue
    if ! grep -qxF -- "$value" <<<"$existing"; then
      git config --file "$global" --add safe.directory "$value" || true
      existing+=$'\n'"$value"
    fi
  done < <(git config --file "$fallback" --null --get-all safe.directory 2>/dev/null)
fi
[ -n "${GITHUB_ENV:-}" ] && echo "GIT_CONFIG_GLOBAL=$global" >>"$GITHUB_ENV"
exit 0
