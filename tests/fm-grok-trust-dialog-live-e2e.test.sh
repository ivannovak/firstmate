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
SCROLLED="$LAB/scrolled-out.txt"
SLICE="$LAB/visible-slice.txt"
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
# Grok runs on the alternate screen by default, where tmux keeps no history at
# all, so a bounded read there returns the viewport and nothing above it. The
# scrolled-out arm below needs the pane to retain what the resize pushed out of
# view, so the option is turned off before Grok has started painting and the
# arm asserts its own precondition rather than trusting that it took.
"$REAL_TMUX" -L "$SOCKET" set-window-option -t "$SESSION" alternate-screen off \
  || fail "could not disable the alternate screen for the isolated Grok pane"

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
# The behavior the gate exists for: the dialog is still waiting, but the pane is
# now too short to show it. Grok repaints a clipped frame - header row and build
# footer, no title and no shortcuts - which is what pushes the complete frame
# above the visible slice in the first place. So a complete frame is never the
# last thing this capture holds, and any rule demanding that it be cannot fire
# here at all.
"$REAL_TMUX" -L "$SOCKET" resize-window -t "$SESSION" -x 80 -y 5 \
  || fail "could not shrink the isolated Grok pane below its trust frame"
repainted=0
for _ in $(seq 1 40); do
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -0 > "$SLICE" 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -120 > "$SCROLLED" 2>/dev/null || true
  if ! grep -Fq 'Do you trust the contents of this directory?' "$SLICE" \
    && grep -Fq 'Do you trust the contents of this directory?' "$SCROLLED"; then
    repainted=1
    break
  fi
  sleep 0.1
done
[ "$repainted" -eq 1 ] \
  || fail "$VERSION did not repaint its trust frame above the visible slice of a shortened pane"
# A visible slice that is no tail of its own bounded history is a pane no
# terminal geometry produces, and a verdict proven only against one proves
# nothing about a real operator's pane.
[ "$(tail -n "$(wc -l < "$SLICE")" "$SCROLLED")" = "$(cat "$SLICE")" ] \
  || fail "the shortened pane's visible slice is not the tail of its own bounded history"
"$CLASSIFIER" active < "$SCROLLED" \
  || fail "$VERSION left a trust dialog waiting above the visible slice that the production classifier did not recognize"
if "$CLASSIFIER" active < "$SLICE"; then
  fail "the classifier read the clipped visible slice alone as an active trust frame"
fi
if "$CLASSIFIER" superseded < "$SCROLLED"; then
  fail "the classifier read a clipped repaint of the waiting frame as a session that had moved past it"
fi
[ ! -e "$ISOLATED_HOME/trusted_folders.toml" ] \
  || fail "the live guard changed its isolated trust store despite never answering the dialog"

printf 'ok - %s: active trust frame recognized in view and scrolled above the visible slice; clipped and historical forms rejected\n' "$VERSION"
