#!/bin/bash
# Quick build and run for local development

set -e

echo "🔨 Building LaserGuide (Debug)..."
xcodebuild -project LaserGuide.xcodeproj \
  -scheme LaserGuide \
  -configuration Debug \
  clean build \
  -derivedDataPath ./build-local \
  CODE_SIGN_IDENTITY="Developer ID Application: ZunSystem Inc. (3QMEVK549R)" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=3QMEVK549R \
  2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" || true

if [ ! -d "build-local/Build/Products/Debug/LaserGuide.app" ]; then
    echo "❌ Build failed"
    exit 1
fi

echo "✅ Build succeeded"
echo ""

# Kill any running instances
echo "♻️ Stopping any running instances..."
pkill -9 LaserGuide 2>/dev/null || true
sleep 0.5

echo "🚀 Launching LaserGuide..."
open build-local/Build/Products/Debug/LaserGuide.app
sleep 0.5

# Check if running
if ps aux | grep -v grep | grep "build-local/Build/Products/Debug/LaserGuide.app" > /dev/null; then
    pid=$(ps aux | grep -v grep | grep "build-local/Build/Products/Debug/LaserGuide.app" | awk '{print $2}')
    echo "✅ LaserGuide is running (PID: $pid)"
    exit 0
else
    echo "❌ Failed to launch"
    exit 1
fi
