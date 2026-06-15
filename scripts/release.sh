#!/usr/bin/env bash
#
# AstroSharper one-command release pipeline (macOS, Apple silicon).
#
# Runs the whole chain so a release never needs hand-holding again:
#   regenerate project → archive → Developer ID export → DMG → notarize
#   → staple → GitHub release   AND   App Store export → upload to ASC.
#
# Credentials (set up once per Mac, no secrets live in this repo):
#   • Notarization uses the keychain profile "AstroSharper". Create it once:
#       xcrun notarytool store-credentials "AstroSharper" \
#         --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
#         --key-id <KEYID> --issuer <ISSUER-UUID>
#   • App Store upload reads the API key from ~/.appstoreconnect/private_keys/
#     and the issuer UUID from ~/.appstoreconnect/issuer_id.txt (gitignored,
#     machine-local). The .p8 key id is auto-detected from the filename.
#
# Version + build come from project.yml (already bumped) unless overridden.
# The version bump commit + push is intentionally NOT done here — bump and
# commit first, run the regression harness, THEN release, so the in-app
# update manifest only ever advertises a build that exists.
#
# Usage:
#   scripts/release.sh                 # version/build from project.yml
#   scripts/release.sh 0.5.3 7         # explicit version + build
#   scripts/release.sh --skip-appstore # GitHub-only (no ASC upload)
#
# Exit non-zero on any failure (set -e); each Apple step is fatal.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

NOTARY_PROFILE="AstroSharper"
ASC_DIR="$HOME/.appstoreconnect"
KEY_FILE="$(ls "$ASC_DIR"/private_keys/AuthKey_*.p8 2>/dev/null | head -1)"
KEY_ID="$(basename "${KEY_FILE:-}" .p8 | sed 's/^AuthKey_//')"
ISSUER="$(cat "$ASC_DIR/issuer_id.txt" 2>/dev/null || true)"

SKIP_APPSTORE=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --skip-appstore) SKIP_APPSTORE=1 ;;
    *) ARGS+=("$a") ;;
  esac
done

VERSION="${ARGS[0]:-$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')}"
BUILD="${ARGS[1]:-$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*: *([0-9]+).*/\1/')}"
TAG="v$VERSION"
DMG="build/AstroSharper-$VERSION.dmg"
ARCHIVE="build/AstroSharper-v${VERSION//./}.xcarchive"

echo "Release $VERSION (build $BUILD) · tag $TAG"
echo "Notary profile: $NOTARY_PROFILE · API key: ${KEY_ID:-MISSING} · issuer: ${ISSUER:+set}"
[[ -n "$KEY_ID" ]] || { echo "No API key in $ASC_DIR/private_keys/"; exit 2; }

# 1. Regenerate project from project.yml so the bumped version is baked in.
xcodegen generate >/dev/null

# 2. Archive (arm64 — Apple silicon native; sidesteps x86_64 Swift issues).
xcodebuild archive -project AstroSharper.xcodeproj -scheme AstroSharper \
  -configuration Release -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO >/dev/null
echo "✓ archived"

# 3. Developer ID export + DMG (for the GitHub download).
rm -rf build/export-rel build/dmg-rel "$DMG"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/export-rel \
  -exportOptionsPlist build/ExportOptions.plist >/dev/null
mkdir -p build/dmg-rel
cp -R build/export-rel/AstroSharper.app build/dmg-rel/
ln -sf /Applications build/dmg-rel/Applications
hdiutil create -volname "AstroSharper $VERSION" -srcfolder build/dmg-rel \
  -ov -format UDZO "$DMG" >/dev/null
echo "✓ DMG: $DMG"

# 4. Notarize + staple (keychain profile — no secrets needed).
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "✓ notarized + stapled"

# 5. GitHub release (skip if the tag already exists).
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --clobber
  echo "✓ uploaded DMG to existing release $TAG"
else
  gh release create "$TAG" "$DMG" --target main --title "AstroSharper $TAG" \
    --notes "AstroSharper $VERSION (build $BUILD). Notarized, Apple silicon (arm64). See CHANGELOG.md."
  echo "✓ created GitHub release $TAG"
fi

# 6. App Store Connect upload.
if [[ "$SKIP_APPSTORE" -eq 1 ]]; then
  echo "↷ App Store upload skipped (--skip-appstore)"
else
  [[ -n "$ISSUER" ]] || { echo "No issuer in $ASC_DIR/issuer_id.txt — skipping ASC upload"; exit 0; }
  rm -rf build/appstore-rel
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/appstore-rel \
    -exportOptionsPlist build/ExportOptions-AppStore-local.plist >/dev/null
  PKG="$(ls build/appstore-rel/*.pkg | head -1)"
  xcrun altool --validate-app -f "$PKG" --type macos --apiKey "$KEY_ID" --apiIssuer "$ISSUER"
  xcrun altool --upload-app   -f "$PKG" --type macos --apiKey "$KEY_ID" --apiIssuer "$ISSUER"
  echo "✓ uploaded build $BUILD to App Store Connect"
fi

echo "Done. Remember: bump + push must happen BEFORE this so the update manifest is valid."
