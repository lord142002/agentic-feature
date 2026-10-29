#!/bin/sh
# Builds and tests both flavours (customer, then developer) and checks that no developer code is left in the customer binary.
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"

has_xctest() { xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; }

echo "== Customer build (flag OFF)"
swift build
if has_xctest; then
  swift test
else
  echo "Full Xcode is unavailable; running the in-app self-test instead of XCTest."
  "$(swift build --show-bin-path)/Bibbles" --router-self-test
fi

echo "== Developer build (flag ON, .build-dev)"
swift build -Xswiftc -DBIBBLES_DEVELOPER --scratch-path .build-dev
if has_xctest; then
  swift test -Xswiftc -DBIBBLES_DEVELOPER --scratch-path .build-dev
else
  "$(swift build -Xswiftc -DBIBBLES_DEVELOPER --scratch-path .build-dev --show-bin-path)/Bibbles" --router-self-test
fi

echo "== Customer release binary: developer strings"
swift build --configuration release --product Bibbles
BINARY="$(swift build --configuration release --show-bin-path)/Bibbles"
FOUND=0
for needle in 'api.anthropic.com' 'x-api-key' 'com.bibbles.dev' 'Developer' 'Router test' 'Local mode' \
              'openrouter.ai' 'api.deepgram.com' 'api.openai.com' 'generativelanguage.googleapis.com'; do
  MATCHES=$(strings "$BINARY" | grep -i -- "$needle" || true)
  if [ -n "$MATCHES" ]; then
    echo "-- '$needle' found:"
    echo "$MATCHES" | head -10
    FOUND=1
  else
    echo "ok: '$needle' not found"
  fi
done
# "who is your developer" (a local answer about who made Bibbles) is the one
# expected match for "Developer"; anything else needs a look.
[ "$FOUND" = "0" ] || echo "Review the matches above."
