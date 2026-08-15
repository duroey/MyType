#!/bin/bash
set -euo pipefail

APP_PATH="${1:-${APP_PATH:-/Applications/mytype.app}}"
APP_VERSION="${APP_VERSION:-1.9.3}"
APP_BUILD="${APP_BUILD:-1}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

read_plist() {
    local key="$1"
    /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null
}

[ -d "$APP_PATH" ] || fail "app bundle not found at $APP_PATH"
[ -f "$INFO_PLIST" ] || fail "Info.plist missing at $INFO_PLIST"
[ -f "$APP_PATH/Contents/MacOS/Type4Me" ] || fail "app executable missing"
[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ] || fail "app icon missing"

[ "$(read_plist CFBundleExecutable)" = "Type4Me" ] || fail "CFBundleExecutable should be Type4Me"
[ "$(read_plist CFBundleIdentifier)" = "com.mytype.app" ] || fail "CFBundleIdentifier should be com.mytype.app"
[ "$(read_plist CFBundleName)" = "MyType" ] || fail "CFBundleName should be MyType"
[ "$(read_plist CFBundleDisplayName)" = "MyType" ] || fail "CFBundleDisplayName should be MyType"
[ "$(read_plist CFBundlePackageType)" = "APPL" ] || fail "CFBundlePackageType should be APPL"
[ "$(read_plist CFBundleShortVersionString)" = "$APP_VERSION" ] || fail "CFBundleShortVersionString should be $APP_VERSION"
[ "$(read_plist CFBundleVersion)" = "$APP_BUILD" ] || fail "CFBundleVersion should be $APP_BUILD"
[ "$(read_plist CFBundleIconFile)" = "AppIcon" ] || fail "CFBundleIconFile should be AppIcon"
[ "$(read_plist LSMinimumSystemVersion)" = "14.0" ] || fail "LSMinimumSystemVersion should be 14.0"
[ -n "$(read_plist NSMicrophoneUsageDescription)" ] || fail "NSMicrophoneUsageDescription should be present"
[ -n "$(read_plist NSAppleEventsUsageDescription)" ] || fail "NSAppleEventsUsageDescription should be present"
[ "$(read_plist LSUIElement)" = "true" ] || fail "LSUIElement should be true"

echo "PASS: app bundle metadata looks correct"
