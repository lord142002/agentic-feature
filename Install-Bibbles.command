#!/bin/bash
set -e
cd "$(dirname "$0")"
echo "Building Bibbles (this can take a few minutes)..."
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple developer tools are missing. Installing them now - re-run this file when that finishes."
  xcode-select --install
  exit 1
fi
sh scripts/build-dev-app.sh
# Close the running copy so the new version is the one that opens.
osascript -e 'tell application "Bibbles" to quit' >/dev/null 2>&1 || true
pkill -x Bibbles >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Bibbles.app
cp -R .build/dev-app/Bibbles.app /Applications/
echo "Installed to /Applications/Bibbles.app - opening it."
open /Applications/Bibbles.app
