#!/usr/bin/env bash
# Build a local menu bar app bundle without installing it.
set -euo pipefail

main() {
  local configuration="${1:-debug}"
  local bin_path
  local app_path=".build/PRDEBar.app"

  swift build -c "${configuration}" --product PRDEBar
  bin_path="$(swift build -c "${configuration}" --show-bin-path)"
  mkdir -p "${app_path}/Contents/MacOS"
  cp "${bin_path}/PRDEBar" "${app_path}/Contents/MacOS/PRDEBar"
  /usr/libexec/PlistBuddy -c 'Clear dict' \
    "${app_path}/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy \
    -c 'Add :CFBundleIdentifier string dev.rselbach.PRDEBar' \
    -c 'Add :CFBundleName string PRDEBar' \
    -c 'Add :CFBundleExecutable string PRDEBar' \
    -c 'Add :CFBundlePackageType string APPL' \
    -c 'Add :CFBundleShortVersionString string 0.1.0' \
    -c 'Add :CFBundleVersion string 1' \
    -c 'Add :LSMinimumSystemVersion string 13.0' \
    -c 'Add :LSUIElement bool true' \
    -c 'Add :NSHighResolutionCapable bool true' \
    "${app_path}/Contents/Info.plist"
  codesign --force --sign - "${app_path}"
  printf 'Built %s\n' "${app_path}"
}

main "$@"
