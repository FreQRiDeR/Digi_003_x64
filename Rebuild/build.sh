#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCE_DIR="${ROOT_DIR}/PrefPaneResources"
OUTPUT_PANE="${ROOT_DIR}/../Avid 003 Family 64.prefPane"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE_DIR="${ROOT_DIR}/.module-cache"
CONTROL_PANEL_APP="${OUTPUT_PANE}/Contents/Resources/Avid003ControlPanel.app"
CONTROL_PANEL_BIN="${CONTROL_PANEL_APP}/Contents/MacOS/Avid003ControlPanel"
MIN_MACOS_X86_64="10.15"
INSTALL_MODE="none"

for arg in "$@"; do
  case "${arg}" in
    --install-system)
      INSTALL_MODE="system"
      ;;
    --install-user)
      INSTALL_MODE="user"
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      echo "Usage: $0 [--install-system | --install-user]" >&2
      exit 1
      ;;
  esac
done

required_resources=(
  "${RESOURCE_DIR}/ProductIcon.icns"
  "${RESOURCE_DIR}/English.lproj/MAFTrampolinePrefPane.nib"
  "${RESOURCE_DIR}/English.lproj/InfoPlist.strings"
  "${RESOURCE_DIR}/English.lproj/Localizable.strings"
)

for resource in "${required_resources[@]}"; do
  if [[ ! -e "${resource}" ]]; then
    echo "Missing required resource: ${resource}" >&2
    exit 1
  fi
done

rm -rf "${OUTPUT_PANE}"
mkdir -p "${OUTPUT_PANE}/Contents/MacOS"
mkdir -p "${OUTPUT_PANE}/Contents/Resources/English.lproj"
mkdir -p "${MODULE_CACHE_DIR}"
mkdir -p "${CONTROL_PANEL_APP}/Contents/MacOS"
mkdir -p "${CONTROL_PANEL_APP}/Contents/Resources"

cp "${ROOT_DIR}/Info.plist" "${OUTPUT_PANE}/Contents/Info.plist"
cp "${RESOURCE_DIR}/ProductIcon.icns" "${OUTPUT_PANE}/Contents/Resources/ProductIcon.icns"
cp "${RESOURCE_DIR}/English.lproj/MAFTrampolinePrefPane.nib" \
  "${OUTPUT_PANE}/Contents/Resources/English.lproj/MAFTrampolinePrefPane.nib"
cp "${RESOURCE_DIR}/English.lproj/InfoPlist.strings" \
  "${OUTPUT_PANE}/Contents/Resources/English.lproj/InfoPlist.strings"
cp "${RESOURCE_DIR}/English.lproj/Localizable.strings" \
  "${OUTPUT_PANE}/Contents/Resources/English.lproj/Localizable.strings"
cp "${ROOT_DIR}/ControlPanel/Info.plist" "${CONTROL_PANEL_APP}/Contents/Info.plist"
cp "${RESOURCE_DIR}/ProductIcon.icns" "${CONTROL_PANEL_APP}/Contents/Resources/ProductIcon.icns"

/usr/libexec/PlistBuddy -c "Delete :LSMinimumSystemVersion" "${OUTPUT_PANE}/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string ${MIN_MACOS_X86_64}" "${OUTPUT_PANE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :LSMinimumSystemVersion" "${CONTROL_PANEL_APP}/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string ${MIN_MACOS_X86_64}" "${CONTROL_PANEL_APP}/Contents/Info.plist"

swiftc \
  -module-cache-path "${MODULE_CACHE_DIR}" \
  -sdk "${SDK_PATH}" \
  -target "x86_64-apple-macos${MIN_MACOS_X86_64}" \
  -O \
  -framework AppKit \
  -framework CoreAudio \
  -framework IOKit \
  "${ROOT_DIR}/ControlPanel/main.swift" \
  -o "${CONTROL_PANEL_BIN}"

clang \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path="${MODULE_CACHE_DIR}" \
  -arch x86_64 \
  -mmacosx-version-min="${MIN_MACOS_X86_64}" \
  -isysroot "${SDK_PATH}" \
  -bundle \
  -framework Cocoa \
  -framework PreferencePanes \
  "${ROOT_DIR}/MAFTrampolinePrefPane003.m" \
  -o "${OUTPUT_PANE}/Contents/MacOS/MAFTrampolinePrefPane"

codesign --force --deep --sign - "${OUTPUT_PANE}"

echo "Built: ${OUTPUT_PANE}"
file "${OUTPUT_PANE}/Contents/MacOS/MAFTrampolinePrefPane"
file "${CONTROL_PANEL_BIN}"

install_pane() {
  local destination_dir="$1"
  local destination="${destination_dir}/$(basename "${OUTPUT_PANE}")"
  mkdir -p "${destination_dir}"
  rm -rf "${destination}"
  ditto "${OUTPUT_PANE}" "${destination}"
  codesign --force --deep --sign - "${destination}"
  echo "Installed: ${destination}"
}

case "${INSTALL_MODE}" in
  system)
    if [[ ! -w "/Library/PreferencePanes" ]]; then
      echo "System install requires administrator privileges." >&2
      echo "Run: sudo bash Rebuild/build.sh --install-system" >&2
      exit 2
    fi
    install_pane "/Library/PreferencePanes"
    ;;
  user)
    install_pane "${HOME}/Library/PreferencePanes"
    ;;
esac
