#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_PANE="${ROOT_DIR}/../Avid 003 Family 64.prefPane"
DEFAULT_PKG_PATH="${ROOT_DIR}/../Avid 003 Family 64 Installer.pkg"
PKG_IDENTIFIER="com.avid.003family.prefpane64"
PKG_PATH="${DEFAULT_PKG_PATH}"
MIN_MACOS_X86_64="10.15"
SKIP_BUILD=0

usage() {
  cat <<EOF2
Usage: $0 [--skip-build] [--output /path/to/installer.pkg]
  --skip-build          Package the existing pref pane without rebuilding.
  --output <path>       Output path for the generated .pkg.
EOF2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --output)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --output" >&2
        usage
        exit 1
      fi
      PKG_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  bash "${ROOT_DIR}/build.sh"
fi

if [[ ! -d "${OUTPUT_PANE}" ]]; then
  echo "Missing built pref pane: ${OUTPUT_PANE}" >&2
  exit 1
fi

if [[ ! -f "${OUTPUT_PANE}/Contents/Info.plist" ]]; then
  echo "Missing Info.plist in pref pane: ${OUTPUT_PANE}" >&2
  exit 1
fi

PKG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${OUTPUT_PANE}/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "${PKG_VERSION}" ]]; then
  PKG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${OUTPUT_PANE}/Contents/Info.plist" 2>/dev/null || true)"
fi
if [[ -z "${PKG_VERSION}" ]]; then
  PKG_VERSION="1.0.0"
fi

mkdir -p "$(dirname "${PKG_PATH}")"
rm -f "${PKG_PATH}"

pkgbuild \
  --component "${OUTPUT_PANE}" \
  --install-location "/Library/PreferencePanes" \
  --identifier "${PKG_IDENTIFIER}" \
  --version "${PKG_VERSION}" \
  --min-os-version "${MIN_MACOS_X86_64}" \
  "${PKG_PATH}"

echo "Created installer package: ${PKG_PATH}"
echo "Minimum supported macOS for this package: ${MIN_MACOS_X86_64}"
echo "Open it in Finder to install; macOS Installer will prompt for admin credentials when required."
