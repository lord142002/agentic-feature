#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
MODULE_CACHE=/tmp/bibbles-module-cache
APP_PATH="$PROJECT_DIR/.build/key-importer/Bibbles Credential Importer.app"
MACOS="$APP_PATH/Contents/MacOS"

mkdir -p "$MACOS"
cp "$PROJECT_DIR/Resources/CredentialImporter-Info.plist" "$APP_PATH/Contents/Info.plist"
swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" -sdk "$SDK_PATH" \
  -target arm64-apple-macosx13.0 "$PROJECT_DIR/Tools/CredentialImporterMain.swift" \
  -o "$MACOS/BibblesCredentialImporter"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "$APP_PATH"
