# shellcheck shell=bash
# Shared branch naming for Firstmate ship tasks.
# Usage: . bin/fm-branch-lib.sh
#
# FM_BRANCH_PREFIX is the single owner of the prefix for newly created branches.
# Ticketed task ids already carry their Linear marker and remain unchanged.
# Unticketed task ids gain the repository's documented dev-000 marker.
# The legacy prefix remains readable so existing branches and open PRs continue
# through review, local merge, teardown, and fleet reporting without migration.

FM_BRANCH_PREFIX='ivannovak/'
FM_BRANCH_LEGACY_PREFIX='fm/'
FM_BRANCH_UNTICKETED_MARKER='dev-000-'

fm_branch_task_slug() {
  local id=$1 ticket
  case "$id" in
    dev-[0-9]*)
      ticket=${id#dev-}
      ticket=${ticket%%-*}
      case "$ticket" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$id"; return 0 ;;
      esac
      ;;
  esac
  printf '%s%s\n' "$FM_BRANCH_UNTICKETED_MARKER" "$id"
}

fm_branch_name() {
  printf '%s%s\n' "$FM_BRANCH_PREFIX" "$(fm_branch_task_slug "$1")"
}

fm_branch_legacy_name() {
  printf '%s%s\n' "$FM_BRANCH_LEGACY_PREFIX" "$1"
}

# Echo the current or legacy local branch for a task, preferring the current
# convention when both exist.
fm_branch_resolve_local() {
  local repo=$1 id=$2 branch
  branch=$(fm_branch_name "$id")
  if git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    printf '%s\n' "$branch"
    return 0
  fi
  branch=$(fm_branch_legacy_name "$id")
  if git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    printf '%s\n' "$branch"
    return 0
  fi
  return 1
}
