#!/usr/bin/env bash
# Notarize a release artifact and staple its ticket to the distributable.
set -euo pipefail

main() {
  : "${APPLE_ID:?Set APPLE_ID before notarizing}"
  : "${APPLE_APP_SPECIFIC_PASSWORD:?Set APPLE_APP_SPECIFIC_PASSWORD before notarizing}"
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID before notarizing}"
  local artifact="${1:?Pass an archive or disk image to notarize}"
  local staple_path="${2:-${artifact}}"
  local result
  local submission_id

  result="$(
    xcrun notarytool submit "${artifact}" \
      --apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}" \
      --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
      --wait --timeout 30m --output-format json
  )"
  if ! printf '%s' "${result}" | jq -e '.status == "Accepted"' >/dev/null; then
    submission_id="$(printf '%s' "${result}" | jq -r '.id')"
    xcrun notarytool log "${submission_id}" \
      --apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}" \
      --password "${APPLE_APP_SPECIFIC_PASSWORD}"
    return 1
  fi
  xcrun stapler staple "${staple_path}"
  xcrun stapler validate "${staple_path}"
}

main "$@"
