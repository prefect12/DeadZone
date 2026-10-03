#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_WORK="$(mktemp -d -t deadzone-windows)"
trap 'rm -rf "$TEST_WORK"' EXIT
python3 - "$REPO/main.swift" "$REPO/tests/WindowAvoiderTests.swift" "$TEST_WORK/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
Path(sys.argv[3]).write_text(source[:source.rindex('let app = NSApplication.shared')] + Path(sys.argv[2]).read_text())
PY
swiftc -swift-version 5 "$TEST_WORK/main.swift" "$REPO/AchievementUI.swift" "$REPO/Medal3D.swift" -o "$TEST_WORK/check"
"$TEST_WORK/check"
