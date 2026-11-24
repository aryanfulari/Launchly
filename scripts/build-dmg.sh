#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
APP_NAME="Launchly"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DIST_DIR="${ROOT_DIR}/dist"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/launchly-dmg.XXXXXX")"

cleanup() {
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

echo "Building Universal Release ${APP_NAME}.app..."
xcodebuild \
  -project "${ROOT_DIR}/Launchly.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${ROOT_DIR}/build" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build

APP_PATH="${ROOT_DIR}/build/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Error: Built app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "Verifying architectures..."
lipo -info "${APP_PATH}/Contents/MacOS/${APP_NAME}"

mkdir -p "${DIST_DIR}"
cp -R "${APP_PATH}" "${STAGE_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGE_DIR}/Applications"

DMG_PATH="${DIST_DIR}/${DMG_NAME}"
rm -f "${DMG_PATH}"

echo "Creating ${DMG_PATH}..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "${DMG_PATH}"

echo "Done:"
ls -lh "${DMG_PATH}"
shasum -a 256 "${DMG_PATH}"
