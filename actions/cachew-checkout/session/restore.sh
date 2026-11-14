#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# After a not-ready fallback in a job with an existing cachew session, the
# official checkout ran against a throwaway copy of the job's global Git file
# (CACHEW_FALLBACK_CONFIG, written by prepare.sh). Point the job back at the
# real file, keeping the safe.directory entries the checkout added, as the
# configure step does for a ready session. Needs only Git and bash 4.
set -u

directory=${CACHEW_SESSION_DIR:-}
fallback=${CACHEW_FALLBACK_CONFIG:-}
[ -n "$directory" ] && [ -f "$directory/global.config" ] || exit 0
global=$directory/global.config

# Only what the checkout added after prepare.sh's snapshot count: anything
# before it came from the job's own files. An empty value resets the list in
# Git, so on both sides only the entries after the last reset count.
skip=$(cat "$fallback.safe-directories" 2>/dev/null) || skip=""
if [ -n "$fallback" ] && [ -f "$fallback" ] && [[ $skip =~ ^[0-9]+$ ]]; then
  mapfile -d '' -t added < <(git config --file "$fallback" --null --get-all safe.directory 2>/dev/null)
  mapfile -d '' -t present < <(git config --file "$global" --includes --null --get-all safe.directory 2>/dev/null)
  for ((i = ${#present[@]} - 1; i >= 0; i--)); do
    [ -n "${present[i]}" ] || { present=("${present[@]:i+1}"); break; }
  done
  for value in "${added[@]:skip}"; do
    if [ -n "$value" ]; then
      for known in "${present[@]}"; do [ "$known" = "$value" ] && continue 2; done
    fi
    git config --file "$global" --add safe.directory "$value" || continue
    if [ -n "$value" ]; then present+=("$value"); else present=(); fi
  done
fi
[ -n "${GITHUB_ENV:-}" ] && echo "GIT_CONFIG_GLOBAL=$global" >>"$GITHUB_ENV"
exit 0
