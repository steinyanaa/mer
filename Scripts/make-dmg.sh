#!/bin/bash
# Builds Mer.app (release) and packages it into dist/Mer-<version>.dmg with a drag-to-Applications layout.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep -A1 CFBundleShortVersionString Scripts/bundle.sh | grep -o '<string>[^<]*' | head -1 | sed 's/<string>//')}"
./Scripts/bundle.sh release

STAGE="$(mktemp -d)/Mer"
mkdir -p "$STAGE"
cp -R dist/Mer.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="dist/Mer-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Mer" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
( cd dist && shasum -a 256 "Mer-$VERSION.dmg" > "Mer-$VERSION.dmg.sha256" )
echo "Built $DMG"
cat "dist/Mer-$VERSION.dmg.sha256"
