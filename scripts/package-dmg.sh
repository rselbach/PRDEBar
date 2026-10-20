#!/usr/bin/env bash
# Package the built app with an Applications shortcut for drag-and-drop install.
set -euo pipefail

main() {
  local dmg_path="${1:-.build/PRDEBar.dmg}"
  local staging_path=".build/dmg"

  rm -rf "${staging_path}"
  mkdir -p "${staging_path}"
  ditto .build/PRDEBar.app "${staging_path}/PRDEBar.app"
  ln -s /Applications "${staging_path}/Applications"
  hdiutil create -volname PRDEBar -srcfolder "${staging_path}" \
    -fs HFS+ -format UDZO -ov "${dmg_path}"
  rm -rf "${staging_path}"
  hdiutil verify "${dmg_path}"
  printf 'Built %s\n' "${dmg_path}"
}

main "$@"
