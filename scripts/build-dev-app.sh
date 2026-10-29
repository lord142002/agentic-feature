#!/bin/sh
# Customer app by default; DEVELOPER=1 builds the developer app (BIBBLES_DEVELOPER flag, .build-dev folder, ".dev" bundle id).
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${DEVELOPER:-0}" = "1" ]; then
  # Developer code is compiled in only with this flag, in its own build folder
  # so customer and developer builds never mix.
  SCRATCH_PATH="$PROJECT_DIR/.build-dev"
  SWIFT_FLAGS="-Xswiftc -DBIBBLES_DEVELOPER"
else
  # SwiftPM's default build folder: the customer build is unchanged.
  SCRATCH_PATH="$PROJECT_DIR/.build"
  SWIFT_FLAGS=""
fi
BUILD_ROOT="$SCRATCH_PATH/dev-app"
APP_PATH="$BUILD_ROOT/Bibbles.app"
CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"

mkdir -p "$MACOS"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
# A Finder-launched app does not inherit the build shell's environment. Embed
# optional PUBLIC analytics settings only in the ignored generated bundle.
python3 - "$CONTENTS/Info.plist" <<'PYCONFIG'
import os, plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as source:
    info = plistlib.load(source)
if os.environ.get('DEVELOPER', '0') == '1':
    # Its own bundle id: separate macOS permissions and Keychain items.
    info['CFBundleIdentifier'] = info['CFBundleIdentifier'] + '.dev'
    info['CFBundleName'] = 'Bibbles Dev'
    # Screen agent: "Use my Contacts card" in Settings → Developer → My details.
    info['NSContactsUsageDescription'] = 'Bibbles reads your own Contacts card only when you ask it to fill My details for forms.'
for environment, key in [('BIBBLES_POSTHOG_PROJECT_TOKEN', 'BibblesPostHogProjectToken'),
                         ('BIBBLES_POSTHOG_HOST', 'BibblesPostHogHost')]:
    value = os.environ.get(environment, '').strip()
    if value:
        info[key] = value
with open(path, 'wb') as target:
    plistlib.dump(info, target)
PYCONFIG
if [ -f "$PROJECT_DIR/Resources/Bibbles.icns" ]; then
  mkdir -p "$CONTENTS/Resources"
  cp "$PROJECT_DIR/Resources/Bibbles.icns" "$CONTENTS/Resources/Bibbles.icns"
fi
# Brand logo: the menu-bar mark (template) and the full-colour logo.
mkdir -p "$CONTENTS/Resources"
for asset in BrandMark.png BrandLogo.png; do
  [ -f "$PROJECT_DIR/Resources/$asset" ] && cp "$PROJECT_DIR/Resources/$asset" "$CONTENTS/Resources/$asset"
done

export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-/private/tmp/bibbles-clang-cache}
export SWIFTPM_MODULECACHE_OVERRIDE=${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/bibbles-swiftpm-cache}

build_arch() {
  if [ "$1" = "arm64" ]; then
    swift build --configuration release --product Bibbles --jobs 4 --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH_PATH" $SWIFT_FLAGS
    BIN_PATH=$(swift build --configuration release --show-bin-path --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH_PATH" $SWIFT_FLAGS)
  else
    swift build --configuration release --product Bibbles --jobs 4 --package-path "$PROJECT_DIR" --triple "$1-apple-macosx13.0" --scratch-path "$SCRATCH_PATH" $SWIFT_FLAGS
    BIN_PATH=$(swift build --configuration release --show-bin-path --package-path "$PROJECT_DIR" --triple "$1-apple-macosx13.0" --scratch-path "$SCRATCH_PATH" $SWIFT_FLAGS)
  fi
  cp "$BIN_PATH/Bibbles" "$2"
  # Native macOS uses these dependency bundles for privacy manifests only.
  # Keep them inside Contents/Resources so the app remains valid for codesign.
  for bundle in "$BIN_PATH"/*PostHog*.bundle "$BIN_PATH"/*PHPLCrashReporter*.bundle; do
    # Force replacement of read-only privacy manifests on subsequent builds.
    [ ! -d "$bundle" ] || cp -Rf "$bundle" "$CONTENTS/Resources/"
  done
}

# BIBBLES_UNIVERSAL=1 builds for both Apple silicon and Intel Macs (for release).
if [ "${BIBBLES_UNIVERSAL:-0}" = "1" ]; then
  build_arch arm64 "$BUILD_ROOT/Bibbles-arm64"
  build_arch x86_64 "$BUILD_ROOT/Bibbles-x86_64"
  lipo -create "$BUILD_ROOT/Bibbles-arm64" "$BUILD_ROOT/Bibbles-x86_64" -output "$MACOS/Bibbles"
else
  build_arch arm64 "$MACOS/Bibbles"
fi

SIGNING_IDENTITY=${BIBBLES_CODESIGN_IDENTITY:-}
if [ -z "$SIGNING_IDENTITY" ]; then
  DEVELOPMENT_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/"Apple Development:/{print $2}')
  if [ -n "$DEVELOPMENT_IDENTITIES" ]; then
    case "$DEVELOPMENT_IDENTITIES" in
      *'
'*) echo "Multiple Apple Development identities found; set BIBBLES_CODESIGN_IDENTITY explicitly." >&2; exit 1 ;;
      *) SIGNING_IDENTITY=$DEVELOPMENT_IDENTITIES ;;
    esac
  fi
fi

if [ -z "$SIGNING_IDENTITY" ]; then
  echo "Warning: no Apple Development signing identity found. Ad-hoc signing changes Bibbles' macOS permission identity on every rebuild." >&2
  SIGNING_IDENTITY=-
fi
if [ "${BIBBLES_APPLE_SIGN_IN:-0}" = "1" ]; then
  /usr/libexec/PlistBuddy -c 'Set :BibblesAppleSignInEnabled true' "$CONTENTS/Info.plist"
  codesign --force --deep --entitlements "$PROJECT_DIR/Resources/AppleSignIn.entitlements" --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
echo "$APP_PATH"
