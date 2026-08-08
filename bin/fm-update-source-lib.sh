# shellcheck shell=bash
# Which git remote firstmate self-updates FROM, and which remote is the
# unmonitored upstream contribution target.
# Usage: . bin/fm-update-source-lib.sh   (no FM_* setup required)
#
# ONE OWNER for resolving both choices, so bin/fm-update.sh,
# bin/fm-absorb-upstream.sh, bin/fm-remote-secondmate-control.sh,
# bin/fm-pr-check.sh, and bin/fm-pr-lib.sh's poll-arming primitive cannot drift
# apart about which remote means what.
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

# A config file these resolvers will read: an ordinary readable file, never a
# symlink. Deliberately stricter than the plain [ -f ] the other firstmate
# config readers use, because these two values decide which remote a whole
# fleet fast-forwards from. One predicate, so the reader below and the warning
# beside it can never disagree about what "usable" means.
fm_update_source_config_file_usable() { # <path>
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]
}

# Say so on stderr when a config file EXISTS but is not usable by that rule,
# naming the file and the behavior taken instead. An absent file is the
# documented unconfigured case and stays silent; a present-but-unusable one is
# the case where silence would let a permissions accident or a stray symlink
# change what the fleet does while the operator's value still reads correctly.
fm_update_source_config_warn_unusable() { # <config-dir> <file-name> <consequence>
  local dir=${1-} name=${2-} path
  [ -n "$dir" ] && [ -n "$name" ] || return 0
  path="$dir/$name"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  fm_update_source_config_file_usable "$path" && return 0
  printf 'warning: %s is not a readable ordinary file; %s\n' "$path" "${3-}" >&2
}

# First meaningful line of a config file: blank lines and "#" comments skipped,
# surrounding whitespace stripped. Echoes nothing when the file is absent, not
# usable by the rule above, or has no meaningful line.
fm_update_source_config_value() { # <config-dir> <file-name>
  local dir=${1-} name=${2-} path line
  [ -n "$dir" ] && [ -n "$name" ] || return 0
  path="$dir/$name"
  fm_update_source_config_file_usable "$path" || return 0
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
# when a configured NAME is unsafe, so a caller refuses rather than silently
# falling back to a different source. An unusable config FILE keeps the "origin"
# default - the shared template's behavior, which upstream reconciliation
# depends on - but says so loudly rather than silently.
# These are this file's OUTPUT variables: assigned here, read by the
# callers that source it (bin/fm-update.sh, bin/fm-absorb-upstream.sh,
# bin/fm-remote-secondmate-control.sh, bin/fm-pr-check.sh, bin/fm-pr-lib.sh).
# ShellCheck sees
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
    fm_update_source_config_warn_unusable "$dir" update-remote \
      "using the default update source 'origin'"
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
  if [ -z "$value" ]; then
    fm_update_source_config_warn_unusable "$dir" upstream-remote \
      "treating this home as having no upstream contribution target"
    return 0
  fi
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

# True only when a pull request at <host>/<project-path> is at the SAME
# repository this home's configured upstream contribution remote points at,
# compared as a normalized forge identity so the three URL spellings and any
# letter case all resolve to one answer.
#
# ONE OWNER of that question, because more than one caller has to answer it
# identically: bin/fm-pr-check.sh at the front door and bin/fm-pr-lib.sh's
# arming primitive, which every poll passes through.
#
# It answers only on a POSITIVE match. No upstream configured, an unsafe
# configured name, a remote that does not exist, or a URL with no forge identity
# all return 1: the unsafe name leaves its reason in FM_UPDATE_SOURCE_ERROR and
# the unresolvable remote leaves one in FM_UPSTREAM_CONTRIBUTION_WARNING, for a
# caller with somewhere to report it. That direction is deliberate and
# load-bearing: this fleet's
# merge polls for every other repository - internal projects and client work -
# must keep waking firstmate, so an unanswerable upstream question must never
# suppress a poll. Failing closed here would silently cost real monitoring.
FM_UPSTREAM_CONTRIBUTION_WARNING=""
fm_upstream_contribution_pr_match() { # <config-dir> <repo-dir> <host> <project-path>
  local config_dir=${1-} repo_dir=${2-} host=${3-} path=${4-} upstream_id pr_id
  FM_UPSTREAM_CONTRIBUTION_WARNING=""
  [ -n "$host" ] && [ -n "$path" ] || return 1
  fm_upstream_contribution_remote_var "$config_dir" || return 1
  [ -n "$FM_UPSTREAM_CONTRIBUTION_REMOTE" ] || return 1
  if ! upstream_id=$(fm_update_source_remote_identity "$repo_dir" "$FM_UPSTREAM_CONTRIBUTION_REMOTE"); then
    # shellcheck disable=SC2034 # Output variable read by callers; see the note above.
    FM_UPSTREAM_CONTRIBUTION_WARNING="upstream contribution remote '$FM_UPSTREAM_CONTRIBUTION_REMOTE' has no resolvable forge identity; not checking this PR against it"
    return 1
  fi
  pr_id=$(printf '%s\t%s\n' \
    "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" \
    "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')")
  [ "$pr_id" = "$upstream_id" ]
}
