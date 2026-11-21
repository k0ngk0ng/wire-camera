#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
WIRECAMERA_MOTION_BACKLOG=600 zsh Tests/motion-e2e.sh "$@"
