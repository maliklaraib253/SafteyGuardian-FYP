#!/bin/bash
# SafetyGuardian: free disk space, then prepare for iPhone testing.
# Run from the project folder:   bash cleanup_and_setup.sh
set -e
cd "$(dirname "$0")"
echo "Size before: $(du -sh . | cut -f1)"

# 1. Build outputs & caches (all regenerated automatically by Flutter/Gradle)
rm -rf build .dart_tool .flutter-plugins-dependencies
rm -rf android/.gradle android/.kotlin android/build android/app/build
rm -f  android/gradle_debug.txt android/gradle_error.txt
rm -rf ios/Flutter/ephemeral ios/Pods ios/.symlinks ios/build ios/Podfile.lock

# 2. Unused files
rm -f flutter_01.png flutter_02.png      # empty 0-byte screenshots

# 3. Unused desktop/web platforms (SafetyGuardian is an Android/iOS app)
rm -rf linux windows macos web

echo "Size after:  $(du -sh . | cut -f1)"

# 4. Resolve packages for the installed Flutter (Dart 3.9.x) and install pods
flutter pub get
cd ios && pod install --repo-update && cd ..

echo ""
echo "Done. Connect your iPhone, then run:  flutter run"
echo "(First time: open ios/Runner.xcworkspace in Xcode once if signing asks for confirmation.)"
