#!/usr/bin/env bash
# Absorb the upstream open-source project's work into the fork this fleet runs
# from. The deliberate counterpart to bin/fm-update.sh: that script brings homes
# UP TO the update source, this one brings the update source up to upstream.
#
# It exists because the two directions have different risk. Advancing a home to
# a commit the fleet already trusts is routine; pulling a third party's history
# into the branch every home fast-forwards from is a decision, so it is a
# separate command a human or the first mate runs on purpose, never a step of
# the ordinary update.
#
# FAST-FORWARD ONLY, the same non-negotiable property as every other firstmate
# sync path:
#   - The only write is a plain, non-forced push of the upstream commit onto the
#     update source's default branch. git itself refuses a non-fast-forward push
#     without --force, and this script never passes --force, so the property is
#     enforced twice: once by the ancestry check below, once by the receiving end.
#   - Nothing is ever pushed to the UPSTREAM remote. This fleet has no authority
#     there, and a contribution goes through an ordinary pull request instead.
#   - Genuine divergence - the fork and upstream both carrying commits the other
#     does not - is REPORTED with its ahead/behind counts and exits non-zero.
#     Reconciling that needs a human decision about which history to keep; this
#     script never merges, rebases, or forces to make it go away.
#   - The local checkout is never touched. Only remote-tracking refs move, from
#     the fetches. bin/fm-update.sh remains the one owner of advancing checkouts.
#
# bin/fm-update-source-lib.sh owns which remotes the two names resolve to and
# docs/configuration.md owns how an operator sets them.
#
# Usage:
#   fm-absorb-upstream.sh [--dry-run]
#   fm-absorb-upstream.sh --help
#
# Output is one parseable result line plus human context:
#   absorb-upstream: current            fork already carries every upstream commit
#   absorb-upstream: absorbed <old>..<new>   upstream fast-forwarded onto the fork
#   absorb-upstream: would-absorb <old>..<new>   --dry-run, nothing written
#   absorb-upstream: diverged ahead=<n> behind=<n>   needs a human, exit 3
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-update-source-lib.sh
. "$SCRIPT_DIR/fm-update-source-lib.sh"

usage() { sed -n '30,38p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

DRY_RUN=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --dry-run) DRY_RUN=1; shift ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "firstmate repo is not a git repository"

fm_update_source_remote_var "$CONFIG" || die "$FM_UPDATE_SOURCE_ERROR"
UPDATE_REMOTE=$FM_UPDATE_SOURCE_REMOTE
fm_upstream_contribution_remote_var "$CONFIG" || die "$FM_UPDATE_SOURCE_ERROR"
UPSTREAM_REMOTE=$FM_UPSTREAM_CONTRIBUTION_REMOTE

if [ -z "$UPSTREAM_REMOTE" ]; then
  die "no upstream contribution remote is configured; see docs/configuration.md"
fi
if [ "$UPSTREAM_REMOTE" = "$UPDATE_REMOTE" ]; then
  die "the upstream remote and the update source remote are both '$UPDATE_REMOTE'; there is nothing to absorb between them"
fi
for remote in "$UPDATE_REMOTE" "$UPSTREAM_REMOTE"; do
  git -C "$FM_ROOT" remote get-url "$remote" >/dev/null 2>&1 \
    || die "no $remote remote in the firstmate repo"
done

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

DEFAULT=$(default_branch "$FM_ROOT" "$UPDATE_REMOTE") \
  || die "cannot determine the default branch"

git -C "$FM_ROOT" fetch "$UPDATE_REMOTE" --prune --quiet 2>/dev/null \
  || die "could not fetch $UPDATE_REMOTE"
git -C "$FM_ROOT" fetch "$UPSTREAM_REMOTE" --prune --quiet 2>/dev/null \
  || die "could not fetch $UPSTREAM_REMOTE"

FORK_REF="$UPDATE_REMOTE/$DEFAULT"
UP_REF="$UPSTREAM_REMOTE/$DEFAULT"
FORK_REV=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$FORK_REF^{commit}") \
  || die "$FORK_REF does not exist"
UP_REV=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$UP_REF^{commit}") \
  || die "$UP_REF does not exist"

printf 'update-source: %s (%s)\n' "$UPDATE_REMOTE" "$FORK_REF"
printf 'upstream: %s (%s)\n' "$UPSTREAM_REMOTE" "$UP_REF"

# Upstream already contained in the fork covers both "identical" and "the fork is
# strictly ahead", which is the steady state of a fork that keeps landing its own
# work. Neither has anything to absorb.
if git -C "$FM_ROOT" merge-base --is-ancestor "$UP_REV" "$FORK_REV" 2>/dev/null; then
  echo "absorb-upstream: current"
  exit 0
fi

if ! git -C "$FM_ROOT" merge-base --is-ancestor "$FORK_REV" "$UP_REV" 2>/dev/null; then
  # Both sides carry commits the other does not. Reconciling is a human decision
  # about history, so report the shape of the divergence and stop.
  AHEAD=$(git -C "$FM_ROOT" rev-list --count "$UP_REV..$FORK_REV" 2>/dev/null || echo '?')
  BEHIND=$(git -C "$FM_ROOT" rev-list --count "$FORK_REV..$UP_REV" 2>/dev/null || echo '?')
  printf 'absorb-upstream: diverged ahead=%s behind=%s\n' "$AHEAD" "$BEHIND"
  printf 'the fork carries %s commit(s) upstream does not and is missing %s of its own; ' "$AHEAD" "$BEHIND" >&2
  printf 'absorbing that needs a decision about which history to keep, so nothing was pushed\n' >&2
  exit 3
fi

SHORT_FORK=$(git -C "$FM_ROOT" rev-parse --short "$FORK_REV")
SHORT_UP=$(git -C "$FM_ROOT" rev-parse --short "$UP_REV")

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'absorb-upstream: would-absorb %s..%s\n' "$SHORT_FORK" "$SHORT_UP"
  exit 0
fi

# A plain push with no --force and no leading "+" in the refspec. The receiving
# end refuses anything that is not a fast-forward, independently of the ancestry
# check above.
if ! PUSH_OUT=$(git -C "$FM_ROOT" push "$UPDATE_REMOTE" \
  "$UP_REV:refs/heads/$DEFAULT" 2>&1); then
  [ -z "$PUSH_OUT" ] || printf '%s\n' "$PUSH_OUT" >&2
  die "could not fast-forward $UPDATE_REMOTE/$DEFAULT to $UPSTREAM_REMOTE/$DEFAULT"
fi

git -C "$FM_ROOT" fetch "$UPDATE_REMOTE" --prune --quiet 2>/dev/null || true
printf 'absorb-upstream: absorbed %s..%s\n' "$SHORT_FORK" "$SHORT_UP"
echo "run bin/fm-update.sh to bring this home and its secondmates to it"
