#!/usr/bin/env bash
# Downloads an archived Unity iOS Xcode export and unpacks it.
#
# Usage: fetch-export.sh --url <https-or-file-url> --dest <dir> [--sha256 <hex>]
#
# Accepted archives: .tar.zst, .zip, .tar.gz, .tar.xz, .tar (detected by content, not by name).
# The archive must contain exactly one Unity-iPhone.xcodeproj. Prints KEY=VALUE lines
# (EXPORT_SHA256, EXPORT_BYTES, EXPORT_DIR, XCODE_KIND, XCODE_PATH) and appends them to $GITHUB_OUTPUT
# if set (as export_sha256, export_bytes, export_dir, kind, path).
# Runs with the bash 3.2 that ships with macOS.
set -euo pipefail

die() { echo "fetch-export: $*" >&2; exit 1; }

url="" dest="" want=""
while [ $# -gt 0 ]; do
  case $1 in
    --url) url=${2:?--url needs a value}; shift 2 ;;
    --dest) dest=${2:?--dest needs a value}; shift 2 ;;
    --sha256) want=${2-}; shift 2 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$url" ] || die "--url is required"
[ -n "$dest" ] || die "--dest is required"
case $url in
  https://* | file://*) ;;
  *) die "the URL must start with https:// (got: $url)" ;;
esac
if [ -n "$want" ]; then
  want=$(printf '%s' "$want" | tr 'A-F' 'a-f')
  printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$' || die "--sha256 must be 64 hex characters"
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$dest"
archive="$dest/export.download"
src="$dest/src"
rm -rf "$archive" "$src"
mkdir -p "$src"

echo "Downloading $url"
curl -fL --silent --show-error --retry 3 --retry-delay 5 --connect-timeout 30 -o "$archive" "$url" \
  || die "download failed"
bytes=$(wc -c <"$archive" | tr -d ' ')
got=$(sha256_of "$archive")
echo "Downloaded $bytes bytes, sha256 $got"
if [ -n "$want" ] && [ "$got" != "$want" ]; then
  die "sha256 mismatch: expected $want"
fi

magic=$(head -c 4 "$archive" | od -An -tx1 | tr -d ' \n')
case $magic in
  504b0304) echo "Unpacking zip"; unzip -q "$archive" -d "$src" ;;
  28b52ffd) echo "Unpacking tar.zst"; zstd -dc "$archive" | tar -xf - -C "$src" ;;
  3c*) die "the link returned an HTML page, not an archive (use a direct download link)" ;;
  *) echo "Unpacking tar"; tar -xf "$archive" -C "$src" ;;
esac
rm -f "$archive"

found=$(find "$src" -name '__MACOSX' -prune -o -type d -name 'Unity-iPhone.xcodeproj' -print -prune)
count=$(printf '%s' "$found" | grep -c . || true)
[ "$count" -eq 1 ] || die "expected exactly one Unity-iPhone.xcodeproj in the archive, found $count${found:+: $found}"
export_dir=$(dirname "$found")
# A workspace (e.g. after CocoaPods) wins over the bare project.
if [ -d "$export_dir/Unity-iPhone.xcworkspace" ]; then
  xcode_kind=--workspace xcode_path=$export_dir/Unity-iPhone.xcworkspace
else
  xcode_kind=--project xcode_path=$found
fi

echo "EXPORT_SHA256=$got"
echo "EXPORT_BYTES=$bytes"
echo "EXPORT_DIR=$export_dir"
echo "XCODE_KIND=$xcode_kind"
echo "XCODE_PATH=$xcode_path"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "export_sha256=$got"
    echo "export_bytes=$bytes"
    echo "export_dir=$export_dir"
    echo "kind=$xcode_kind"
    echo "path=$xcode_path"
  } >>"$GITHUB_OUTPUT"
fi
