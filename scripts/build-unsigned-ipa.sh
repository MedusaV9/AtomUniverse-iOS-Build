#!/usr/bin/env bash
# Archives an iOS app without code signing and packs it as an unsigned .ipa.
#
# Usage: build-unsigned-ipa.sh (--project <x.xcodeproj> | --workspace <x.xcworkspace>) --scheme <scheme>
#                              --name <prefix> --version <version> --out <dir> [--configuration Release]
#
# Runs `xcodebuild archive` for generic iOS devices with CODE_SIGNING_ALLOWED=NO, CODE_SIGNING_REQUIRED=NO
# and an empty CODE_SIGN_IDENTITY, then zips Payload/<App>.app into <out>/<prefix>-<version>-unsigned.ipa.
# The full xcodebuild log is <out>/xcodebuild-archive.log. Prints KEY=VALUE lines (IPA_PATH, IPA_NAME,
# IPA_BYTES, IPA_SHA256, APP_NAME, ARCHIVE_SECONDS) and appends them in lower case to $GITHUB_OUTPUT if set.
# Runs with the bash 3.2 that ships with macOS.
set -euo pipefail

die() { echo "build-unsigned-ipa: $*" >&2; exit 1; }

kind="" path="" scheme="" name="" version="" out="" configuration=Release
while [ $# -gt 0 ]; do
  case $1 in
    --project) kind=-project; path=${2:?--project needs a value}; shift 2 ;;
    --workspace) kind=-workspace; path=${2:?--workspace needs a value}; shift 2 ;;
    --scheme) scheme=${2:?--scheme needs a value}; shift 2 ;;
    --name) name=${2:?--name needs a value}; shift 2 ;;
    --version) version=${2:?--version needs a value}; shift 2 ;;
    --out) out=${2:?--out needs a value}; shift 2 ;;
    --configuration) configuration=${2:?--configuration needs a value}; shift 2 ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$kind" ] || die "--project or --workspace is required"
[ -e "$path" ] || die "not found: $path"
[ -n "$scheme" ] || die "--scheme is required"
[ -n "$out" ] || die "--out is required"
for value in "$name" "$version"; do
  printf '%s' "$value" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || die "--name and --version may only use A-Z a-z 0-9 . _ - (got: '$value')"
done

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$out"
out=$(cd "$out" && pwd)
archive="$out/$name.xcarchive"
log="$out/xcodebuild-archive.log"
stage="$out/ipa-stage"
ipa_name="$name-$version-unsigned.ipa"
ipa="$out/$ipa_name"
rm -rf "$archive" "$stage" "$ipa"

xcodebuild -version
echo "Archiving $path (scheme $scheme, $configuration, generic iOS device, no code signing)"
start=$(date +%s)
if ! xcodebuild archive \
  "$kind" "$path" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -derivedDataPath "$out/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  >"$log" 2>&1; then
  tail -n 80 "$log" >&2
  die "xcodebuild archive failed, full log: $log"
fi
seconds=$(($(date +%s) - start))
grep -E 'warning:|error:|\*\* ARCHIVE' "$log" | tail -n 40 || true
echo "Archive done in ${seconds}s"

apps=$(find "$archive/Products/Applications" -maxdepth 1 -type d -name '*.app' 2>/dev/null || true)
count=$(printf '%s' "$apps" | grep -c . || true)
[ "$count" -eq 1 ] || die "expected one .app in $archive/Products/Applications, found $count"
app_name=$(basename "$apps")
if [ -d "$apps/_CodeSignature" ]; then
  echo "::warning::$app_name contains _CodeSignature although code signing was disabled"
fi

mkdir -p "$stage/Payload"
if command -v ditto >/dev/null 2>&1; then
  ditto "$apps" "$stage/Payload/$app_name"
else
  cp -R "$apps" "$stage/Payload/"
fi
(cd "$stage" && zip -qry -X "$ipa" Payload)
rm -rf "$stage"

unzip -l "$ipa" | grep -q "Payload/$app_name/Info.plist" || die "Payload/$app_name/Info.plist missing in $ipa"
bytes=$(wc -c <"$ipa" | tr -d ' ')
sha=$(sha256_of "$ipa")

echo "IPA_PATH=$ipa"
echo "IPA_NAME=$ipa_name"
echo "IPA_BYTES=$bytes"
echo "IPA_SHA256=$sha"
echo "APP_NAME=$app_name"
echo "ARCHIVE_SECONDS=$seconds"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "ipa_path=$ipa"
    echo "ipa_name=$ipa_name"
    echo "ipa_bytes=$bytes"
    echo "ipa_sha256=$sha"
    echo "app_name=$app_name"
    echo "archive_seconds=$seconds"
  } >>"$GITHUB_OUTPUT"
fi
