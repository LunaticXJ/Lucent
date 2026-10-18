#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
destination="$repo_dir/Vendor/VLCKit/VLCKit.xcframework"
url='https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip'
checksum='f37c8dbdd4427d1a3f5d75dc4b8bd1ae863cef4426f9a405a2fd1c5c9012f1fb'

if [[ -d "$destination" ]]; then
  echo "VLCKit already exists at $destination"
  exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
curl --fail --location --retry 3 "$url" --output "$work_dir/VLCKit.zip"
actual_checksum="$(shasum -a 256 "$work_dir/VLCKit.zip" | awk '{print $1}')"
if [[ "$actual_checksum" != "$checksum" ]]; then
  echo "VLCKit checksum mismatch" >&2
  exit 1
fi

unzip -q "$work_dir/VLCKit.zip" -d "$work_dir/extracted"
framework="$(find "$work_dir/extracted" -type d -name VLCKit.xcframework -print -quit)"
if [[ -z "$framework" ]]; then
  echo "VLCKit.xcframework not found in downloaded archive" >&2
  exit 1
fi

mkdir -p "$(dirname "$destination")"
mv "$framework" "$destination"
echo "Installed VLCKit at $destination"
