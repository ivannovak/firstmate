# shellcheck shell=bash
# Which git remote firstmate self-updates FROM, and which remote is the
# unmonitored upstream contribution target.
# Usage: . bin/fm-update-source-lib.sh   (no FM_* setup required)
#
# ONE OWNER for resolving both choices, so bin/fm-update.sh,
# bin/fm-absorb-upstream.sh, bin/fm-remote-secondmate-control.sh, and
# bin/fm-pr-check.sh cannot drift apart about which remote means what.
# docs/configuration.md owns what the two choices are for and how an operator
# sets them; this file owns the resolution order and the safety rules on a value.
#
# Firstmate is a shared template that a home may run from its own fork. The two
# choices are independent:
#   update source        - the remote every home in this fleet fast-forwards
#                          from. Defaults to "origin", which is exactly what a
#                          home with no config file has always used, so an
#                          unconfigured install behaves as before.
#   upstream contribution - the open-source project this fork contributes back
#                          to. It has NO default: a home that has not named one
#                          has no upstream, and every upstream-specific behavior
#                          stays inert.
#
# Both are remote NAMES rather than URLs, so the URL stays in git's own remote
# configuration where an operator can inspect and change it with git, and this
# repo never carries one captain's fork address in tracked material.

# A git remote name safe to hand to git as a positional argument: no leading
# dash a later command line could absorb as a flag, and no shell or path
# metacharacters. Deliberately narrower than git's own accepted set.
fm_update_source_remote_name_safe() { # <name>
  local name=${1-}
  case $name in
    '' | -*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#name}" -le 64 ] || return 1
  return 0
}

# First meaningful line of a config file: blank lines and "#" comments skipped,
# surrounding whitespace stripped. Echoes nothing when the file is absent,
# unreadable, a symlink, or has no meaningful line.
fm_update_source_config_value() { # <config-dir> <file-name>
  local dir=${1-} name=${2-} path line
  [ -n "$dir" ] && [ -n "$name" ] || return 0
  path="$dir/$name"
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case $line in
      '' | '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$path"
  return 0
}

# Both resolvers ASSIGN rather than print, so a caller reads the value and the
# refusal reason from its own shell. A printing variant would have to be read
# through a command substitution, and the subshell that runs would take the
# diagnostic with it when it exits - leaving a caller able to detect that
# resolution failed but unable to say why.

# The remote this home fast-forwards its own tracked files from, into
# FM_UPDATE_SOURCE_REMOTE: FM_UPDATE_REMOTE, then <config-dir>/update-remote,
# then "origin". Returns 1 with FM_UPDATE_SOURCE_ERROR set and the value cleared
# when a configured name is unsafe, so a caller refuses rather than silently
# falling back to a different source.
# These three are this file's OUTPUT variables: assigned here, read by the
# callers that source it (bin/fm-update.sh, bin/fm-absorb-upstream.sh,
# bin/fm-remote-secondmate-control.sh, bin/fm-pr-check.sh). ShellCheck sees
# only this file when it is linted as its own root, so the cross-file read is
# invisible to it here.
FM_UPDATE_SOURCE_REMOTE=""
FM_UPDATE_SOURCE_ERROR=""
fm_update_source_remote_var() { # [config-dir]
  local dir=${1-} value
  FM_UPDATE_SOURCE_REMOTE=""
  FM_UPDATE_SOURCE_ERROR=""
  value=${FM_UPDATE_REMOTE-}
  if [ -z "$value" ]; then
    value=$(fm_update_source_config_value "$dir" update-remote)
  fi
  if [ -z "$value" ]; then
    # shellcheck disable=SC2034 # Output variable read by callers; see the note above.
    FM_UPDATE_SOURCE_REMOTE=origin
    return 0
  fi
  if ! fm_update_source_remote_name_safe "$value"; then
    # shellcheck disable=SC2034 # Output variable read by callers; see the note above.
    FM_UPDATE_SOURCE_ERROR="update source is not a safe git remote name"
    return 1
  fi
  # shellcheck disable=SC2034 # Output variable read by callers; see the note above.
  FM_UPDATE_SOURCE_REMOTE=$value
}

# The remote naming the upstream open-source project this fork contributes to,
# into FM_UPSTREAM_CONTRIBUTION_REMOTE: FM_UPSTREAM_REMOTE, then
# <config-dir>/upstream-remote, then unset. An empty value with return 0 means
# this home has no upstream; return 1 with FM_UPDATE_SOURCE_ERROR set means a
# configured name is unsafe.
FM_UPSTREAM_CONTRIBUTION_REMOTE=""
fm_upstream_contribution_remote_var() { # [config-dir]
  local dir=${1-} value
  FM_UPSTREAM_CONTRIBUTION_REMOTE=""
  FM_UPDATE_SOURCE_ERROR=""
  value=${FM_UPSTREAM_REMOTE-}
  if [ -z "$value" ]; then
    value=$(fm_update_source_config_value "$dir" upstream-remote)
  fi
  [ -n "$value" ] || return 0
  if ! fm_update_source_remote_name_safe "$value"; then
    # shellcheck disable=SC2034 # Output variable read by callers; see the note above.
    FM_UPDATE_SOURCE_ERROR="upstream contribution target is not a safe git remote name"
    return 1
  fi
  # shellcheck disable=SC2034 # Output variable read by callers; see the note above.
  FM_UPSTREAM_CONTRIBUTION_REMOTE=$value
}

# Normalize a git remote URL to "<host><TAB><owner>/<repo>", lowercased, with
# any ".git" suffix and trailing slashes removed. Handles the three forms git
# remotes actually take for a forge: https://host/path, ssh://user@host/path
# (and git://, http://), and the scp-like user@host:path. Returns 1 for
# anything else - a local path, a file: URL, or a form with no host - because
# those cannot be a forge pull request target and must never match one.
fm_update_source_forge_identity() { # <url>
  local url=${1-} rest authority host path
  case $url in
    '' | -*) return 1 ;;
    *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac
  case $url in
    https://?* | http://?* | ssh://?* | git://?*)
      rest=${url#*://}
      authority=${rest%%/*}
      case $rest in
        */*) path=${rest#*/} ;;
        *) return 1 ;;
      esac
      ;;
    *:*)
      # scp-like: [user@]host:path. A colon before any slash, and never a
      # bracketed IPv6 literal or a Windows drive letter, which are not forges.
      case ${url%%:*} in
        */*) return 1 ;;
      esac
      case $url in
        \[*) return 1 ;;
      esac
      authority=${url%%:*}
      path=${url#*:}
      case $path in
        /*) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac

  host=${authority##*@}
  host=${host%%:*}
  [ -n "$host" ] || return 1
  case $host in
    *[!A-Za-z0-9.-]*) return 1 ;;
  esac

  path=${path%/}
  path=${path%.git}
  path=${path%/}
  [ -n "$path" ] || return 1
  case $path in
    */*) ;;
    *) return 1 ;;
  esac
  case $path in
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac

  printf '%s\t%s\n' \
    "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" \
    "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
}

# The forge identity of <remote> in <repo-dir>, as fm_update_source_forge_identity
# output. Returns 1 when the repo, the remote, or the URL shape cannot supply one.
fm_update_source_remote_identity() { # <repo-dir> <remote>
  local dir=${1-} remote=${2-} url
  [ -n "$dir" ] && [ -n "$remote" ] || return 1
  fm_update_source_remote_name_safe "$remote" || return 1
  url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) || return 1
  fm_update_source_forge_identity "$url"
}
