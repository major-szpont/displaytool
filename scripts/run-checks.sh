#!/usr/bin/env bash
# Compiles the safety, DDC-framing and EDID code with the self-check runner, then runs it.
# Needs only Command Line Tools (no XCTest or Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/checks"
mkdir -p build
swiftc -o "$OUT" \
    Tests/SelfChecks/main.swift \
    Sources/DisplayTool/Safety.swift \
    Sources/DisplayTool/DDC.swift \
    Sources/DisplayTool/EDID.swift \
    -framework IOKit
"$OUT"
