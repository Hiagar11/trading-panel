#!/bin/bash
# Build APK wrapper for agents — use this instead of raw gradlew
# Usage: bash scripts/build-apk.sh [--no-analyze]

set -e

REPO=/home/glados/repos/trading-panel
FLUTTER_ENV=/home/glados/factories/flutter/env.sh
APK_SRC="$REPO/build/app/outputs/flutter-apk/app-release.apk"
APK_DST_1="$APK_SRC"
APK_DST_2="/var/www/html/app-release.apk"

source "$FLUTTER_ENV"

cd "$REPO"

# Pre-build: sync kCurrentBuild with pubspec.yaml
PUBSPEC_VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //' | tr -d ' ')
BUILD_NUM=$(echo "$PUBSPEC_VERSION" | cut -d'+' -f2)
SEMVER=$(echo "$PUBSPEC_VERSION" | cut -d'+' -f1)

echo "==> pubspec version: $PUBSPEC_VERSION (build: $BUILD_NUM)"

# Check kCurrentBuild in main.dart
CURRENT_BUILD=$(grep 'kCurrentBuild' lib/main.dart | grep -o '[0-9]*' || echo "NOT_FOUND")
if [ "$CURRENT_BUILD" != "$BUILD_NUM" ]; then
  echo "ERROR: kCurrentBuild=$CURRENT_BUILD but pubspec build=$BUILD_NUM — sync first!"
  echo "Fix: update kCurrentBuild = $BUILD_NUM and kCurrentVersion = '$SEMVER' in lib/main.dart"
  exit 1
fi

# Pre-build analyze
if [ "$1" != "--no-analyze" ]; then
  echo "==> flutter analyze..."
  ERRORS=$(flutter analyze --no-fatal-infos 2>&1 | grep -E "^error" || true)
  if [ -n "$ERRORS" ]; then
    echo "ERROR: flutter analyze found errors:"
    echo "$ERRORS"
    exit 1
  fi
  echo "==> analyze: clean"
fi

# Build
echo "==> building APK..."
cd android && ./gradlew assembleRelease
cd "$REPO"

# Deploy
echo "==> deploying..."
if [ -d "$(dirname $APK_DST_2)" ]; then
  cp "$APK_SRC" "$APK_DST_2"
  echo "==> deployed to $APK_DST_2"
else
  echo "WARN: $APK_DST_2 dir not found, skipping secondary deploy"
fi

# Update version.txt
echo "$PUBSPEC_VERSION" > version.txt
echo "==> version.txt: $PUBSPEC_VERSION"

# Verify
echo "==> verify: $(ls -lh $APK_SRC | awk '{print $5, $9}')"
echo "==> DONE: APK built and deployed"
