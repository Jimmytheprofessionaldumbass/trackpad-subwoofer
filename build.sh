#!/bin/sh
# Builds trackpad-subwoofer as one program for Apple Silicon and Intel Macs.
#
#   ./build.sh    build ./trackpad-subwoofer
#
# Needs Xcode or the Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

fail() {
    printf '\n  trackpad-subwoofer: %s\n\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "this builds on macOS only (it drives a Mac's trackpad)."

# /usr/bin/swiftc exists even without developer tools (it only offers to install them), so ask xcode-select.
{ xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; } || fail "Swift isn't installed. Install Apple's Command Line Tools:

    xcode-select --install

  then run ./build.sh again."

version=$(swiftc --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
set -- $version
if [ -z "$1" ] || [ "$1" -lt 5 ] || { [ "$1" -eq 5 ] && [ "$2" -lt 7 ]; }; then
    fail "this needs Swift 5.7 or newer, and found ${1:-?}.${2:-?}. Update Xcode or the Command Line Tools
  (Software Update, or: xcode-select --install)."
fi

# macOS 14.2 is the floor: capturing system output uses AudioHardwareCreateProcessTap.
mkdir -p build
echo "building for Apple Silicon…"
swiftc -O -target arm64-apple-macos14.2 trackpad-subwoofer.swift -o build/trackpad-subwoofer-arm64 \
    || fail "the Apple Silicon build failed (errors above). Make sure Xcode or the Command Line Tools are up to date."

echo "building for Intel…"
swiftc -O -target x86_64-apple-macos14.2 trackpad-subwoofer.swift -o build/trackpad-subwoofer-x86_64 \
    || fail "the Intel build failed (errors above). Make sure Xcode or the Command Line Tools are up to date."

lipo -create build/trackpad-subwoofer-arm64 build/trackpad-subwoofer-x86_64 -output build/trackpad-subwoofer
codesign -s - -f build/trackpad-subwoofer 2>/dev/null || true
mv -f build/trackpad-subwoofer trackpad-subwoofer     # a rename, so a copy that's already running isn't disturbed
echo "built ./trackpad-subwoofer ($(lipo -archs trackpad-subwoofer)). Run it with: ./trackpad-subwoofer"
