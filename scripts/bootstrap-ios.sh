#!/usr/bin/env bash
# Generates ios/PhotoBooth.xcodeproj with XcodeGen and leaves it ready to open.
# Usage: ./scripts/bootstrap-ios.sh [--open]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS="$ROOT/ios"
missing=0

note() { printf '  %s\n' "$@"; }

echo "Checking development tools…"
if ! xcode_path="$(xcode-select -p 2>/dev/null)" || [[ "$xcode_path" != *Xcode*.app* ]]; then
  echo "✘ Xcode is not selected as the active developer directory."
  note "Install Xcode from the App Store, open it once, then run:" \
       "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  missing=1
else
  echo "✔ $(xcodebuild -version | head -1) ($xcode_path)"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✘ XcodeGen is not installed."
  note "Install it with Homebrew:   brew install xcodegen" \
       "or Mint:                    mint install yonaskolb/XcodeGen" \
       "or see https://github.com/yonaskolb/XcodeGen#installing"
  missing=1
else
  echo "✔ XcodeGen $(xcodegen --version 2>/dev/null | awk '{print $NF}')"
fi

if [[ $missing -ne 0 ]]; then
  echo
  echo "Install the missing tools above and run this script again."
  exit 1
fi

CONFIG_DIR="$IOS/PhotoBooth/Config"
if [[ ! -f "$CONFIG_DIR/Local.xcconfig" ]]; then
  echo "ℹ No ios/PhotoBooth/Config/Local.xcconfig — using the placeholder bundle id com.example.photobooth."
  note "For a device build, copy Local.xcconfig.example to Local.xcconfig and set" \
       "PHOTOBOOTH_BUNDLE_ID and DEVELOPMENT_TEAM, or choose a team in Xcode's Signing tab."
fi

echo "Generating Xcode project…"
(cd "$IOS" && xcodegen generate --quiet)

echo "Resolving Swift packages…"
# The app has no third-party packages today; this keeps the step in place for later.
xcodebuild -resolvePackageDependencies -project "$IOS/PhotoBooth.xcodeproj" -scheme PhotoBooth >/dev/null 2>&1 || true

echo
echo "✔ Ready: $IOS/PhotoBooth.xcodeproj"
note "Simulator (mock camera): select an iPhone or iPad simulator and Run." \
     "Device: choose your team under Signing & Capabilities, connect the device and Run." \
     "Tests:  xcodebuild test -project ios/PhotoBooth.xcodeproj -scheme PhotoBooth -destination 'platform=iOS Simulator,name=iPhone 17'"

if [[ "${1:-}" == "--open" ]]; then open "$IOS/PhotoBooth.xcodeproj"; fi
