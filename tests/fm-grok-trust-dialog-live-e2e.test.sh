#!/usr/bin/env bash
# Token-free live drift guard for Grok's project-folder trust frame and
# Firstmate's active-versus-historical classifier.
#
# The guard launches the installed Grok with no prompt in an isolated git
# directory containing one inert project hook. It copies only the existing
# authentication file into a private throwaway GROK_HOME, never answers the
# dialog, and never changes the operator's trust store. A missing credential is
# a capability skip by default and a failure when this guard or FM_LIVE is
# explicitly forced.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_GROK_TRUST_DIALOG_LIVE grok tmux git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/bin/fm-grok-trust.sh"
REAL_GROK=$(command -v grok)
REAL_TMUX=$(command -v tmux)
SOURCE_GROK_HOME=${GROK_HOME:-${HOME:-}/.grok}
REQUESTED=${FM_GROK_TRUST_DIALOG_LIVE:-${FM_LIVE:-0}}

if [ ! -s "$SOURCE_GROK_HOME/auth.json" ]; then
  if [ "$REQUESTED" = 1 ]; then
    fail "FM_GROK_TRUST_DIALOG_LIVE was requested but $SOURCE_GROK_HOME/auth.json is absent or empty"
  fi
  printf 'skip: live: grok authentication absent at %s/auth.json\n' "$SOURCE_GROK_HOME"
  exit 0
fi

LAB=$(fm_test_tmproot fm-grok-trust-live)
PROJECT="$LAB/project"
ISOLATED_HOME="$LAB/grok-home"
SOCKET="fm-grok-trust-live-$$"
SESSION="grok-trust"
CAPTURE="$LAB/active.txt"
VERSION=$($REAL_GROK --version 2>&1 | head -1)

cleanup_grok_trust_live() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_grok_trust_live EXIT
trap 'cleanup_grok_trust_live; exit 130' INT
trap 'cleanup_grok_trust_live; exit 143' TERM

mkdir -p "$PROJECT/.grok/hooks" "$ISOLATED_HOME"
chmod 700 "$ISOLATED_HOME"
cp "$SOURCE_GROK_HOME/auth.json" "$ISOLATED_HOME/auth.json"
chmod 600 "$ISOLATED_HOME/auth.json"
git -C "$PROJECT" init -q || fail "could not initialize the isolated Grok project"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"true"}]}]}}' \
  > "$PROJECT/.grok/hooks/fm-trust-probe.json"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 80 -y 12 -c "$PROJECT" \
  "exec env GROK_HOME='$ISOLATED_HOME' '$REAL_GROK' --always-approve" \
  || fail "could not launch $VERSION in the isolated tmux server"

found=0
for _ in $(seq 1 40); do
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -120 > "$CAPTURE" 2>/dev/null || true
  if grep -Fq 'Do you trust the contents of this directory?' "$CAPTURE"; then
    found=1
    break
  fi
  sleep 0.1
done
[ "$found" -eq 1 ] || fail "$VERSION did not render the project-folder trust dialog"

"$CLASSIFIER" active < "$CAPTURE" \
  || fail "$VERSION rendered a trust dialog that the production classifier did not recognize"
if tail -n 2 "$CAPTURE" | "$CLASSIFIER" active; then
  fail "the classifier accepted a visible tail that omitted the active dialog"
fi
if { cat "$CAPTURE"; printf '%s\n' 'Tip: current Grok session' 'Weekly limit left: 50%'; } \
  | "$CLASSIFIER" active; then
  fail "the classifier accepted trust text followed by a newer session surface"
fi
[ ! -e "$ISOLATED_HOME/trusted_folders.toml" ] \
  || fail "the live guard changed its isolated trust store despite never answering the dialog"

printf 'ok - %s: active trust frame recognized from bounded history; clipped and historical forms rejected\n' "$VERSION"
