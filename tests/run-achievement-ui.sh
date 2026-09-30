#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$REPO}"
OUTPUT="${2:-$REPO/build/achievement-qa}"
TEST_WORK="$(mktemp -d -t deadzone-achievements)"
trap 'rm -rf "$TEST_WORK"' EXIT
python3 - "$SOURCE/main.swift" "$REPO/tests/AchievementUITests.swift" "$TEST_WORK/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
entry=source.rindex('let app = NSApplication.shared')
Path(sys.argv[3]).write_text(source[:entry]+Path(sys.argv[2]).read_text())
PY
SOURCES=("$TEST_WORK/main.swift" "$SOURCE/AchievementUI.swift" "$SOURCE/Medal3D.swift")
swiftc -swift-version 5 "${SOURCES[@]}" -o "$TEST_WORK/check"
DEADZONE_RENDER_RESOURCES="$SOURCE/Resources" "$TEST_WORK/check" "$OUTPUT/zh" -language zh
DEADZONE_RENDER_RESOURCES="$SOURCE/Resources" "$TEST_WORK/check" "$OUTPUT/en" -language en
