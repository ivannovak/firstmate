#!/usr/bin/env bash
# Classify whether a bounded plain-text Grok pane capture ends in the active
# project-folder trust dialog.
# Usage: fm-grok-trust.sh active   # reads the capture from stdin
# Exit 0 means the last trust frame is active; exit 1 means it is absent,
# incomplete, or followed by later pane content.
#
# Grok can render the dialog above the visible slice of a short pane, so the
# caller supplies a bounded history capture rather than a viewport-only read.
# Historical dialog text is not active: the complete final frame must end with
# the affirmative and negative shortcuts followed only by Grok's build footer.
# Any nonblank content after that footer makes the verdict negative.
set -u

case "${1:-}" in
  active) ;;
  *)
    echo "usage: fm-grok-trust.sh active" >&2
    exit 2
    ;;
esac

awk '
  index($0, "Do you trust the contents of this directory?") {
    phase = 1
    yes = 0
    no = 0
    footer = 0
    invalid = 0
    next
  }
  phase == 0 { next }
  /^[[:space:]]*$/ { next }
  phase == 1 && /Yes, proceed[[:space:]]+y[[:space:]]*$/ {
    yes = 1
    phase = 2
    next
  }
  phase == 2 && /No, quit[[:space:]]+n[[:space:]]*$/ {
    no = 1
    phase = 3
    next
  }
  phase == 3 && /Grok Build[[:space:]]+[0-9][^[:space:]]*[[:space:]]+\[[^]]+\][[:space:]]*$/ {
    footer = 1
    phase = 4
    next
  }
  phase == 1 { next }
  { invalid = 1 }
  END {
    exit !(phase == 4 && yes == 1 && no == 1 && footer == 1 && invalid == 0)
  }
'
