#!/bin/zsh
# Builds a signed, notarized release of Ant AI Launcher.
#
#   ./release.sh               sign with Developer ID, notarize, staple, zip into dist/
#   ./release.sh --publish     …then create GitHub Release v<VERSION> with the zip attached
#   ./release.sh --dry-run     same steps signed ad hoc and without notarization (to test the pipeline)
#
# One-time setup (see README "Releasing"):
#   - a "Developer ID Application" certificate in your login keychain
#   - notarization credentials saved as a keychain profile:
#       xcrun notarytool store-credentials ant-ai-launcher --apple-id <apple id> --team-id <team id>
#
# Optional environment:
#   SIGN_IDENTITY   full identity name; default: the first "Developer ID Application" identity found
#   NOTARY_PROFILE  notarytool keychain profile; default: ant-ai-launcher
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Ant AI Launcher"
EXECUTABLE="AntAILauncher"
REPO="AntCodeLabs/ant-ai-launcher"
ENTITLEMENTS="Resources/AntAILauncher.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-ant-ai-launcher}"
PUBLISH=false; DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
$PUBLISH && $DRY_RUN && { echo "--publish and --dry-run can't be combined." >&2; exit 2; }

step() { print -P "%F{green}==>%f $1"; }
fail() { print -P "%F{red}error:%f $1" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/${APP_NAME}.app"
ZIP="dist/Ant-AI-Launcher-${VERSION}.zip"

# Signing identity.
if $DRY_RUN; then
  IDENTITY="-"
else
  IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
  [[ -n "$IDENTITY" ]] || fail "No \"Developer ID Application\" certificate found. Create one at developer.apple.com → Certificates (or Xcode → Settings → Accounts → Manage Certificates), then run again."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "No notarization credentials in keychain profile \"$NOTARY_PROFILE\". Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id <team id>"
fi

if $PUBLISH; then
  [[ -z "$(git status --porcelain)" ]] || fail "Commit your changes before publishing."
  gh release view "v${VERSION}" --repo "$REPO" >/dev/null 2>&1 && fail "Release v${VERSION} already exists. Bump VERSION first."
fi

step "Building v${VERSION}"
./build.sh

step "Checking the app for personal paths and secrets"
BIN="$APP/Contents/MacOS/$EXECUTABLE"
if strings -a "$BIN" | grep -E "$HOME|/Users/[^/]+/" >/dev/null; then
  strings -a "$BIN" | grep -E "$HOME|/Users/[^/]+/" | sort -u | head >&2
  fail "The binary contains local paths (shown above)."
fi
if grep -rIlE 'sk-ant-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY' "$APP" >/dev/null 2>&1; then
  fail "Something that looks like a credential is inside the app bundle."
fi

step "Signing with: $($DRY_RUN && echo "ad hoc (dry run)" || echo "$IDENTITY")"
if $DRY_RUN; then
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
else
  codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

mkdir -p dist
if $DRY_RUN; then
  step "Skipping notarization (dry run)"
else
  step "Notarizing (this usually takes a few minutes)"
  SUBMIT_ZIP="build/notarize.zip"
  rm -f "$SUBMIT_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMIT_ZIP"
  RESULT="$(xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  STATUS="$(print -r -- "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  if [[ "$STATUS" != "Accepted" ]]; then
    ID="$(print -r -- "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2
    fail "Notarization status: ${STATUS:-unknown}"
  fi
  step "Stapling the notarization ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

step "Packaging"
rm -f "$ZIP" "$ZIP.sha256"
# No extended attributes or resource forks: they'd add __MACOSX/ files carrying this Mac's
# com.apple.provenance tag (a per-machine ID). The signature and stapled ticket live inside the app.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
if zipinfo -1 "$ZIP" | grep -q '__MACOSX'; then fail "The zip contains __MACOSX metadata."; fi
(cd dist && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")
echo "$ZIP"
cat "$ZIP.sha256"

if $PUBLISH; then
  step "Publishing GitHub Release v${VERSION}"
  gh release create "v${VERSION}" "$ZIP" "$ZIP.sha256" --repo "$REPO" \
    --title "Ant AI Launcher ${VERSION}" --generate-notes
fi
step "Done"
