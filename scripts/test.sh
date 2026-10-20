#!/usr/bin/env bash
# Load the bundled Testing plugin omitted by Swift 6.4 command-line builds.
set -euo pipefail

main() {
  local swiftc_path
  local toolchain_path
  local plugin_path
  local flags=()

  swiftc_path="$(xcrun --find swiftc)"
  toolchain_path="$(dirname "$(dirname "${swiftc_path}")")"
  plugin_path="${toolchain_path}/lib/swift/host/plugins/testing"
  plugin_path="${plugin_path}/libTestingMacros.dylib"
  if [[ -f "${plugin_path}" ]]; then
    flags=(-Xswiftc -load-plugin-library -Xswiftc "${plugin_path}")
  fi
  swift test "${flags[@]}" "$@"
}

main "$@"
