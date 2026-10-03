#!/usr/bin/env bash
# Generates the Xcode project and builds the demo for the iPad simulator.
# Usage: ./build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")"
config="${1:-Release}"
xcodegen generate --quiet
xcodebuild -project ToolchainDemo.xcodeproj -scheme ToolchainDemo \
  -configuration "$config" -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
echo "app: $(pwd)/build/DerivedData/Build/Products/$config-iphonesimulator/ToolchainDemo.app"
