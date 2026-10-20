#!/usr/bin/env bash
# Build a menu bar app bundle without installing it.
set -euo pipefail

main() {
  local configuration="${1:-debug}"
  local version="${APP_VERSION:-0.1.0}"
  local build_number="${APP_BUILD_NUMBER:-1}"
  local bin_path
  local rpaths
  local rpath
  local app_path=".build/PRDEBar.app"
  local executable="${app_path}/Contents/MacOS/PRDEBar"
  local sparkle_path=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework"

  swift build -c "${configuration}" --product PRDEBar "${@:2}"
  bin_path="$(swift build -c "${configuration}" --show-bin-path "${@:2}")"
  mkdir -p "${app_path}/Contents/MacOS" \
    "${app_path}/Contents/Frameworks" "${app_path}/Contents/Resources"
  cp "${bin_path}/PRDEBar" "${executable}"
  rpaths="$(
    otool -l "${executable}" \
      | awk '/cmd LC_RPATH/ {
        getline; getline
        sub(/^[[:space:]]*path /, ""); sub(/ \(offset.*$/, "")
        print
      }' \
      | sort -u
  )"
  while IFS= read -r rpath; do
    case "${rpath}" in
      /usr/lib/swift | @*) ;;
      /*) install_name_tool -delete_rpath "${rpath}" "${executable}" ;;
    esac
  done <<< "${rpaths}"
  rm -rf "${app_path}/Contents/Frameworks/Sparkle.framework"
  ditto "${sparkle_path}/macos-arm64_x86_64/Sparkle.framework" \
    "${app_path}/Contents/Frameworks/Sparkle.framework"
  cp .build/artifacts/sparkle/Sparkle/LICENSE \
    "${app_path}/Contents/Resources/Sparkle-LICENSE"
  cp Resources/Info.plist "${app_path}/Contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleShortVersionString string ${version}" \
    -c "Add :CFBundleVersion string ${build_number}" \
    "${app_path}/Contents/Info.plist"
  codesign --force --sign - "${app_path}"
  printf 'Built %s\n' "${app_path}"
}

main "$@"
