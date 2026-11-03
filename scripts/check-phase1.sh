#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_JOBS=${BIBBLES_BUILD_JOBS:-4}

# Resolve Auth, PostHog and transitive dependencies through the real package.
# Raw swiftc invocations no longer represent this app's build graph.
if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
  swift test --package-path "$PROJECT_DIR" --jobs "$BUILD_JOBS"
else
  echo "Full Xcode is unavailable; building and running offline contract checks instead of XCTest."
  swift build --package-path "$PROJECT_DIR" --jobs "$BUILD_JOBS"
fi
BIN_PATH=$(swift build --package-path "$PROJECT_DIR" --show-bin-path)
"$BIN_PATH/Bibbles" --router-self-test

if command -v node >/dev/null 2>&1; then
  node --test "$PROJECT_DIR/billing-worker/test/billing.test.mjs"
else
  echo "Node.js is unavailable; billing Worker tests were not run."
fi
