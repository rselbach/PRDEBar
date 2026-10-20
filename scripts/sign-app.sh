#!/usr/bin/env bash
# Sign PRDEBar and Sparkle's nested code for Developer ID distribution.
set -euo pipefail

main() {
  : "${APPLE_SIGNING_IDENTITY:?Set APPLE_SIGNING_IDENTITY before signing}"
  local app_path="${1:-.build/PRDEBar.app}"
  local framework="${app_path}/Contents/Frameworks/Sparkle.framework"
  local version="${framework}/Versions/B"
  local target
  local flags=(
    --force --options runtime --timestamp
    --sign "${APPLE_SIGNING_IDENTITY}"
  )

  codesign "${flags[@]}" --preserve-metadata=entitlements \
    "${version}/XPCServices/Downloader.xpc"
  for target in \
    "${version}/XPCServices/Installer.xpc" \
    "${version}/Autoupdate" \
    "${version}/Updater.app" \
    "${framework}" \
    "${app_path}"; do
    codesign "${flags[@]}" "${target}"
  done
  codesign --verify --deep --strict "${app_path}"
}

main "$@"
