#!/usr/bin/env bash
#
# Embed discoverable entitlements in an otherwise anonymously-built iOS app before packaging it
# for AltStore / SideStore. The ad-hoc signature is not an Apple distribution signature and is
# replaced by the user's sideloader. Its purpose is to preserve the capability request inside each
# Mach-O so AltSign can provision the matching App IDs and shared App Group before re-signing.
#
# Usage:
#   Tools/prepare-ios-sideload-app.sh path/to/NOOP.app

set -euo pipefail

APP="${1:?usage: $0 path/to/NOOP.app}"
[ -d "$APP" ] || { echo "no such app bundle: $APP" >&2; exit 1; }

WIDGET="$APP/PlugIns/NOOPWidgets.appex"
[ -d "$WIDGET" ] || { echo "widget extension missing: $WIDGET" >&2; exit 1; }

APP_INFO="$APP/Info.plist"
WIDGET_INFO="$WIDGET/Info.plist"
APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$APP_INFO")
WIDGET_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$WIDGET_INFO")

[ -n "$APP_GROUP" ] || { echo "app AppGroupIdentifier is empty" >&2; exit 1; }
[ "$APP_GROUP" = "$WIDGET_GROUP" ] || {
  echo "App Group mismatch: app=$APP_GROUP widget=$WIDGET_GROUP" >&2
  exit 1
}

ENTITLEMENTS_DIR=$(mktemp -d /tmp/noop-sideload-entitlements.XXXXXX)
cleanup() {
  if [ -n "${ENTITLEMENTS_DIR:-}" ] && [ -d "$ENTITLEMENTS_DIR" ]; then
    rm -rf "$ENTITLEMENTS_DIR"
  fi
}
trap cleanup EXIT

APP_ENTITLEMENTS="$ENTITLEMENTS_DIR/app.plist"
WIDGET_ENTITLEMENTS="$ENTITLEMENTS_DIR/widget.plist"

plutil -create xml1 "$APP_ENTITLEMENTS"
plutil -insert 'com\.apple\.developer\.healthkit' -bool YES "$APP_ENTITLEMENTS"
plutil -insert 'com\.apple\.developer\.healthkit\.access' -array "$APP_ENTITLEMENTS"
plutil -insert 'com\.apple\.security\.application-groups' -array "$APP_ENTITLEMENTS"
plutil -insert 'com\.apple\.security\.application-groups.0' -string "$APP_GROUP" "$APP_ENTITLEMENTS"

plutil -create xml1 "$WIDGET_ENTITLEMENTS"
plutil -insert 'com\.apple\.security\.application-groups' -array "$WIDGET_ENTITLEMENTS"
plutil -insert 'com\.apple\.security\.application-groups.0' -string "$APP_GROUP" "$WIDGET_ENTITLEMENTS"

# First sign every nested framework/bundle so the outer seal can be verified. Then replace the
# extension and app signatures with their target-specific entitlements, signing from the inside out.
codesign --force --deep --sign - "$APP"
codesign --force --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET"
codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "$APP"

SIGNED_APP_ENTITLEMENTS="$ENTITLEMENTS_DIR/signed-app.plist"
SIGNED_WIDGET_ENTITLEMENTS="$ENTITLEMENTS_DIR/signed-widget.plist"
codesign -d --entitlements :- "$APP" 2>/dev/null > "$SIGNED_APP_ENTITLEMENTS"
codesign -d --entitlements :- "$WIDGET" 2>/dev/null > "$SIGNED_WIDGET_ENTITLEMENTS"

SIGNED_APP_GROUP=$(/usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.application-groups:0' "$SIGNED_APP_ENTITLEMENTS")
SIGNED_WIDGET_GROUP=$(/usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.application-groups:0' "$SIGNED_WIDGET_ENTITLEMENTS")

[ "$SIGNED_APP_GROUP" = "$APP_GROUP" ] || {
  echo "signed app lost App Group entitlement" >&2
  exit 1
}
[ "$SIGNED_WIDGET_GROUP" = "$APP_GROUP" ] || {
  echo "signed widget lost App Group entitlement" >&2
  exit 1
}

codesign --verify --deep --strict "$APP"
echo "✓ sideload capability template embedded for app + widget: $APP_GROUP"
