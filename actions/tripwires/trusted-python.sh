# shellcheck shell=bash disable=SC2034
# SPDX-FileCopyrightText: © 2026 Tenstorrent USA, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# The interpreter that runs the tripwires. Sourced with '.', never run.
#
# The checks cannot choose their own interpreter: it is found on PATH before
# anything is checked, and a pull request can put a file named python3 in the
# workspace. This file takes the first interpreter on PATH that is not there.
#
# Set before sourcing:
#   trusted_python_names  names to look for, in order (for example
#                           "python3 python")
# Reads:  PATH GITHUB_WORKSPACE
# Sets:   trusted_python  absolute path of the interpreter, or "" when PATH
#                           has none outside the workspace
#         trusted_python_problem  when trusted_python is "", why, as one
#                           fixed sentence for an annotation (never a path,
#                           which PATH controls); otherwise ""
#
# An entry of PATH is used only when it is absolute and when its directory,
# with every link followed, is outside the workspace with every link followed.
# So another spelling of the workspace (/proc/self/cwd, a link) is still the
# workspace. A workspace virtual environment first on PATH is skipped, not
# refused: the checks run on the next interpreter. The interpreter must be
# Python 3.9 or newer.
#
# Limit: the interpreter file itself can be a link (/usr/bin/python3 usually
# is), and bash cannot read where a link leads without a command from PATH. A
# link outside the workspace that leads into it is not detected; making one
# takes code that already runs on the runner.
#
# Only builtins, parameter expansion and exec: no command from PATH.

trusted_python=""
trusted_python_problem=""
tripwires_seen=""
tripwires_workspace=""
if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
  tripwires_workspace="$(builtin cd -P -- "$GITHUB_WORKSPACE" 2>/dev/null && builtin pwd -P)" || tripwires_workspace=""
fi
tripwires_rest="${PATH:-}:"
while [[ -n "$tripwires_rest" ]]; do
  tripwires_entry="${tripwires_rest%%:*}"
  tripwires_rest="${tripwires_rest#*:}"
  tripwires_directory="$(builtin cd -P -- "$tripwires_entry" 2>/dev/null && builtin pwd -P)" || continue
  tripwires_where=outside
  [[ "$tripwires_entry" == /* ]] || tripwires_where=relative
  if [[ -n "$tripwires_workspace" ]]; then
    case "$tripwires_directory/" in
      "$tripwires_workspace"/*) tripwires_where=workspace ;;
    esac
  fi
  for tripwires_name in ${trusted_python_names:-python3}; do
    # A name is one file name: never a path that leaves the directory.
    [[ "$tripwires_name" != */* ]] || continue
    [[ -f "$tripwires_directory/$tripwires_name" && -x "$tripwires_directory/$tripwires_name" ]] || continue
    # Only noted, never run: the reason the search failed, outside first.
    if [[ "$tripwires_where" != outside ]]; then
      [[ "$tripwires_seen" == old ]] || tripwires_seen="$tripwires_where"
      continue
    fi
    tripwires_seen=old
    # -I: PYTHONPATH and the user site cannot replace a module. POSIX mode, on
    # a line of its own, so that exec is the builtin and not a function.
    if (
      POSIXLY_CORRECT=1
      exec "$tripwires_directory/$tripwires_name" -I -c 'import sys; sys.exit(sys.version_info < (3, 9))'
    ) >/dev/null 2>&1; then
      trusted_python="$tripwires_directory/$tripwires_name"
      break 2
    fi
  done
done
tripwires_need="The checks need Python 3.9 or newer on PATH, outside the workspace."
case "$trusted_python:$tripwires_seen" in
  :old) trusted_python_problem="Python on PATH outside the workspace is older than 3.9 or does not start. $tripwires_need" ;;
  :workspace) trusted_python_problem="The only Python on PATH is inside the workspace. $tripwires_need" ;;
  :relative) trusted_python_problem="The only Python on PATH is in a relative PATH entry. $tripwires_need" ;;
  :) trusted_python_problem="There is no Python on PATH. $tripwires_need" ;;
esac
unset tripwires_rest tripwires_entry tripwires_directory tripwires_name tripwires_workspace tripwires_where tripwires_seen tripwires_need
