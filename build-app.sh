#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

LAUNCH=true
for arg in "$@"; do
    case "${arg}" in
        --no-launch) LAUNCH=false ;;
    esac
done

APP="The Dragon.app"
BUNDLE_ID="com.tim.thedragon"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppInfo.plist 2>/dev/null || true)"
VERSION="${VERSION:-1.0.0}"

if [[ ! -f Assets/AppIcon.icns ]]; then
    echo "Generating app icon..."
    swift Scripts/GenerateAppIcon.swift
fi

echo "Building The Dragon ${VERSION} (release)..."
swift build -c release

BIN=".build/release/TheDragon"
if [[ ! -x "${BIN}" ]]; then
    echo "error: expected binary not found at ${BIN}" >&2
    exit 1
fi

echo "Running self-test..."
"${BIN}" --self-test

echo "Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/The Dragon"
chmod +x "${APP}/Contents/MacOS/The Dragon"
cp AppInfo.plist "${APP}/Contents/Info.plist"
cp README.md CHANGELOG.md SECURITY.md LICENSE "${APP}/Contents/Resources/"

copy_docs() {
    local name="$1"
    local dir="$2"
    mkdir -p "${APP}/Contents/Resources/${name}"
    cp "${dir}/README.md" "${dir}/FORMAT.md" "${dir}/SECURITY.md" "${dir}/CHANGELOG.md" \
        "${APP}/Contents/Resources/${name}/"
    cp LICENSE "${APP}/Contents/Resources/${name}/LICENSE"
}

copy_docs Curve Docs/Curve
copy_docs Scale Docs/Scale
copy_docs Fold Docs/Fold
copy_docs Reel Docs/Reel

if [[ -f Assets/AppIcon.icns ]]; then
    cp Assets/AppIcon.icns "${APP}/Contents/Resources/"
fi

echo "Signing ${APP}..."
xattr -cr "${APP}" 2>/dev/null || true
codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}/Contents/MacOS/The Dragon"
codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}"

plutil -lint "${APP}/Contents/Info.plist" >/dev/null
codesign --verify --verbose=2 "${APP}" 2>/dev/null || codesign --verify "${APP}"

if [[ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(pwd)/${APP}" 2>/dev/null || true
fi

echo "Done: ${APP} (v${VERSION})"
if [[ "${LAUNCH}" == "true" ]]; then
    pkill -x "The Dragon" 2>/dev/null || true
    sleep 0.2
    echo "Launching..."
    open "${APP}"
fi
