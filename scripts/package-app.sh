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
  local iconset_path=".build/PRDEBar.iconset"
  local size

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
  mkdir -p "${iconset_path}"
  for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" prde.jpg --setProperty format png \
      --out "${iconset_path}/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" prde.jpg \
      --setProperty format png \
      --out "${iconset_path}/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil --convert icns "${iconset_path}" \
    --output "${app_path}/Contents/Resources/PRDEBar.icns"
  cp Resources/Info.plist "${app_path}/Contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleShortVersionString string ${version}" \
    -c "Add :CFBundleVersion string ${build_number}" \
    "${app_path}/Contents/Info.plist"
  codesign --force --sign - "${app_path}"
  printf 'Built %s\n' "${app_path}"
}

main "$@"
