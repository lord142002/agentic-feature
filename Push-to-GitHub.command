#!/bin/bash
# Double-click to check, commit and push your Bibbles changes to GitHub.
#
# Safety:
# - Builds and runs the tests first, so broken code is never pushed.
# - Stages only app files: changes to files already in git, plus new files
#   inside Sources/, Tests/, Resources/, scripts/, docs/, Tools/ and billing-worker/. Anything
#   else (notes, exports, downloads) is listed and left out.
# - Blocks API keys and files larger than 5 MB.
# - Shows exactly what will be pushed and asks before pushing.
# - Pushes to a new branch; you merge it on GitHub.
set -uo pipefail
cd "$(dirname "$0")"

AUTHOR_NAME="Mohit Singh"
AUTHOR_EMAIL="mohit55599@gmail.com"
REPO_URL="https://github.com/jtn-dev/Bibbles"
LOG="${TMPDIR:-/tmp}/bibbles-push-check.log"
APP_DIRS=(Sources Tests Resources scripts docs Tools billing-worker)
MAX_BYTES=$((5 * 1024 * 1024))

finish() { echo; read -r -p "Press Return to close this window." _; exit "${1:-0}"; }
unstage() { git reset -q; }

echo "=== Push Bibbles to GitHub ==="
echo

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "This folder is not a git repository."; finish 1
fi
if [ -n "$(git diff --cached --name-only)" ]; then
  echo "Some files are already staged from before. Unstaging them so you can review everything."
  unstage
fi
if [ -z "$(git status --porcelain)" ]; then
  echo "Nothing new to push - everything is already on GitHub."; finish 0
fi

echo "Step 1 of 5: Building Bibbles and running the tests (a few minutes)..."
if ! sh scripts/build-dev-app.sh >"$LOG" 2>&1; then
  echo; echo "The BUILD failed, so nothing was pushed:"
  grep -E "error:" "$LOG" | head -20 || tail -30 "$LOG"
  echo "Full log: $LOG"; finish 1
fi
TEST_LOG="${TMPDIR:-/tmp}/bibbles-push-tests.log"
if swift test >"$TEST_LOG" 2>&1; then
  echo "   Build and tests OK."
elif grep -qE "no such module 'XCTest'|unable to find utility \"xctest\"|XCTest.*not found" "$TEST_LOG"; then
  echo "   Build OK. Tests skipped: this Mac has no XCTest (install Xcode to run them)."
else
  echo; echo "The TESTS failed, so nothing was pushed:"
  grep -E "error:|failed" "$TEST_LOG" | head -25 || tail -30 "$TEST_LOG"
  echo "Full log: $TEST_LOG"; finish 1
fi

echo "Step 2 of 5: Choosing files (app files only)..."
git add -u
for dir in "${APP_DIRS[@]}"; do
  [ -d "$dir" ] && git add -- "$dir"
done
for file in Package.swift README.md .gitignore *.command; do
  [ -f "$file" ] && git add -- "$file"
done

LEFT_OUT=$(git ls-files --others --exclude-standard)
if [ -z "$(git diff --cached --name-only)" ]; then
  echo "No app files changed. Nothing to push."
  [ -n "$LEFT_OUT" ] && { echo "Other new files (not pushed):"; echo "$LEFT_OUT" | sed 's/^/   /'; }
  finish 0
fi

echo "Step 3 of 5: Checking for API keys and very large files..."
TOO_BIG=""
while IFS= read -r file; do
  [ -f "$file" ] || continue
  size=$(wc -c <"$file" | tr -d ' ')
  [ "$size" -gt "$MAX_BYTES" ] && TOO_BIG="$TOO_BIG\n   $file ($((size / 1024 / 1024)) MB)"
done < <(git diff --cached --name-only --diff-filter=AM)
if [ -n "$TOO_BIG" ]; then
  unstage
  echo; echo -e "STOPPED: these files are larger than 5 MB:$TOO_BIG"
  echo "Nothing was pushed."; finish 1
fi
if git diff --cached -U0 | grep -E '^\+' \
   | grep -nE 'sk-ant-[A-Za-z0-9_-]{20,}|sk-or-v1-[A-Za-z0-9]{20,}|sk_[a-f0-9]{40,}|xi-api-key"?: *"[A-Za-z0-9]{20,}|(deepgram|DEEPGRAM)[^\n]{0,40}[a-f0-9]{40}|-----BEGIN [A-Z ]*PRIVATE KEY-----|whsec_[A-Za-z0-9+/=]{20,}|(^|[^A-Za-z0-9_.-])[A-Za-z0-9_-]{12,24}\.[A-Za-z0-9_-]{40,}($|[^A-Za-z0-9_.-])|(service_role|SERVICE_ROLE_KEY)[^\n]{0,10}[=:][^\n]{0,4}eyJ[A-Za-z0-9_-]{20,}'; then
  unstage
  echo; echo "STOPPED: the lines above look like a real API key or private key. Nothing was pushed."
  echo "Remove it from the file (app keys belong in the Keychain; payment keys only in `wrangler secret put`), then try again."
  finish 1
fi
echo "   No keys or large files."

echo
echo "These files WILL be pushed:"
git diff --cached --name-status | sed 's/^/   /'
if [ -n "$LEFT_OUT" ]; then
  echo
  echo "These new files are NOT included (not app files):"
  echo "$LEFT_OUT" | sed 's/^/   /'
fi
echo
read -r -p "Step 4 of 5: Push these files? Type y and press Return: " ANSWER
if [ "$ANSWER" != "y" ] && [ "$ANSWER" != "Y" ]; then
  unstage
  echo "Cancelled. Nothing was pushed; your files are unchanged."; finish 0
fi
DEFAULT_MSG="Update Bibbles"
read -r -p "Describe this update (or press Return for \"$DEFAULT_MSG\"): " MSG
MSG=${MSG:-$DEFAULT_MSG}

if ! git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" commit -q -m "$MSG"; then
  unstage; echo "Commit failed. Nothing was pushed."; finish 1
fi
echo "   Saved as commit $(git rev-parse --short HEAD)."

BRANCH="update-$(date +%Y%m%d-%H%M)"
echo "Step 5 of 5: Uploading to GitHub (branch $BRANCH)..."
if ! git push origin "HEAD:refs/heads/$BRANCH"; then
  echo
  echo "The upload failed (check your internet or GitHub sign-in)."
  echo "Your changes are kept and nothing is lost; run this file again."
  git reset -q --soft HEAD~1
  unstage
  finish 1
fi

PR_URL="$REPO_URL/compare/main...$BRANCH?expand=1"
echo
echo "Done! Opening GitHub - click \"Create pull request\", review the files, then \"Merge pull request\"."
echo "$PR_URL"
open "$PR_URL"
finish 0
