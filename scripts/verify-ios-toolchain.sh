#!/usr/bin/env bash
set -euo pipefail

xcode_version="$(xcodebuild -version)"
printf '%s\n' "$xcode_version"
if ! grep -q -E '^Xcode 27([.]|$)' <<< "$xcode_version"; then
  echo 'iOS builds require Xcode 27.' >&2
  exit 1
fi
for sdk in iphoneos iphonesimulator; do
  sdk_version="$(xcrun --sdk "$sdk" --show-sdk-version)"
  printf '%s SDK: %s\n' "$sdk" "$sdk_version"
  if [[ ! "$sdk_version" =~ ^27[.][0-9]+([.][0-9]+)?$ ]]; then
    echo "The $sdk SDK must be iOS 27." >&2
    exit 1
  fi
done
