#!/bin/bash
# Hardware-independent checks only. Never call apply/restore or run a display-mutating harness.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -Xswiftc -warnings-as-errors
swift test
swift build -c release -Xswiftc -warnings-as-errors
swift test -c release
bash -n Scripts/build-app.sh Scripts/check.sh
git diff --check
printf '\nAll automated checks passed (no live display mutations).\n'
