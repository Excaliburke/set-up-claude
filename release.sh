#!/bin/bash
#
# Publishes a new version of Origami on GitHub.
#
#   bash release.sh 1.1.0 "What changed, in a sentence or two."
#
# It sets the version, builds the app, signs it with the Developer ID,
# has Apple notarize it, and creates a GitHub release with these files:
#   Origami.zip         the app
#   Set-Up-Claude.zip   the same app, for links from before the rename
#   claude-setup.sh     the script, for the Terminal route
#   latest.json         the version, download address, and checksum
#
# Copies of the app already out there read latest.json from the newest
# release when they open, and offer the update. Nothing is published until
# the build, signing and notarization have all worked.
#
# Needs: the GitHub CLI signed in (gh auth login), the Developer ID
# certificate in this Mac's keychain, and the "set-up-claude" notarization
# login (see README.md).

set -euo pipefail

REPO="Excaliburke/set-up-claude"
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Brian Burke (YX5UZDLY5F)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-set-up-claude}"

usage() {
  echo "Usage: bash release.sh <version> \"<what changed>\""
  echo "Example: bash release.sh 1.1.0 \"Clearer message when Apple's installer is cancelled.\""
  exit 1
}
VERSION=${1:-}
NOTES=${2:-}
[ -n "$VERSION" ] && [ -n "$NOTES" ] || usage

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

# ---- Checks before anything changes ----------------------------------------

if ! [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "The version should look like 1.2.3."
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "There are uncommitted changes. Commit them first, so the release matches the code on GitHub."
  exit 1
fi
if [ "$(git rev-parse --abbrev-ref HEAD)" != main ]; then
  echo "Releases are made from the main branch."
  exit 1
fi
if ! gh auth status > /dev/null 2>&1; then
  echo "Sign in to GitHub first: gh auth login"
  exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null; then
  echo "Version $VERSION has already been released."
  exit 1
fi
newest=$(gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null | sed 's/^v//' || true)
if [ -n "$newest" ]; then
  # The new version has to sort after the newest release, or the app won't offer it.
  highest=$(printf '%s\n%s\n' "$newest" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
  if [ "$highest" != "$VERSION" ] || [ "$newest" = "$VERSION" ]; then
    echo "The newest release is $newest, so the new version has to be higher than that."
    exit 1
  fi
fi
git fetch --quiet origin main
# Being ahead is fine (a version commit from an earlier attempt, say); being behind isn't.
if ! git merge-base --is-ancestor origin/main HEAD; then
  echo "GitHub has changes this copy doesn't. Pull first: git pull"
  exit 1
fi

# ---- Version ---------------------------------------------------------------

if [ "$(tr -d '[:space:]' < VERSION)" != "$VERSION" ]; then
  echo "$VERSION" > VERSION
  sed -i '' -E "s/^SETUP_VERSION=\"[^\"]*\"/SETUP_VERSION=\"$VERSION\"/" claude-setup.sh
  git add VERSION claude-setup.sh
  git commit --quiet -m "Version $VERSION"
fi

# ---- Build, sign, notarize -------------------------------------------------

DEVELOPER_ID="$DEVELOPER_ID" NOTARY_PROFILE="$NOTARY_PROFILE" bash app/build-app.sh

APP="dist/Origami.app"
ZIP="dist/Origami.zip"
if ! spctl --assess --type execute "$APP" 2> /dev/null; then
  echo "Gatekeeper doesn't accept the built app, so nothing was published."
  exit 1
fi
built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
if [ "$built" != "$VERSION" ]; then
  echo "The app says it's version $built, not $VERSION, so nothing was published."
  exit 1
fi

cp claude-setup.sh dist/claude-setup.sh
# The same app under its old name, so download links shared before the
# rename (Set Up Claude became Origami) keep working.
cp "$ZIP" dist/Set-Up-Claude.zip
osascript -l JavaScript -e 'function run(a) {
  return JSON.stringify({ version: a[0], url: a[1], sha256: a[2], notes: a[3], minimumSystemVersion: "13.0" }, null, 2)
}' "$VERSION" "https://github.com/$REPO/releases/download/v$VERSION/Origami.zip" \
  "$(shasum -a 256 "$ZIP" | awk '{print $1}')" "$NOTES" > dist/latest.json

# ---- Publish ---------------------------------------------------------------

git tag -a "v$VERSION" -m "Origami $VERSION"
git push --quiet origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" dist/Set-Up-Claude.zip dist/claude-setup.sh dist/latest.json \
  --repo "$REPO" --title "Origami $VERSION" --notes "$NOTES" --latest

echo
echo "Released $VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
echo "Link to share: https://github.com/$REPO/releases/latest/download/Origami.zip"
