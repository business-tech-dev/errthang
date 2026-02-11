#!/bin/bash

# Build errthang.app package script
# Usage: ./build-app.sh

set -e

echo "🔨 Building errthang.app package..."

# 1. Build release version
echo "📦 Building release binary..."
swift build --configuration release

# 2. Clean previous build
echo "🧹 Cleaning previous .app build..."
rm -rf errthang.app

# 3. Create .app structure
echo "📁 Creating .app directory structure..."
mkdir -p errthang.app/Contents/MacOS
mkdir -p errthang.app/Contents/Resources

# 4. Create Info.plist
echo "📄 Creating Info.plist..."
cat > errthang.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>errthang</string>
    <key>CFBundleIdentifier</key>
    <string>com.errthang.app</string>
    <key>CFBundleName</key>
    <string>errthang</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 5. Copy binary and resources
echo "📋 Copying binary and resources to .app package..."
cp .build/release/errthang errthang.app/Contents/MacOS/
cp .build/release/errthang-service errthang.app/Contents/MacOS/
if [ -f "Sources/errthang/Resources/AppIcon.icns" ]; then
    echo "🖼️ Copying AppIcon.icns..."
    cp Sources/errthang/Resources/AppIcon.icns errthang.app/Contents/Resources/
else
    echo "⚠️ AppIcon.icns not found, skipping icon copy"
fi

if [ -f "Sources/errthang/Resources/AppLogo.jpg" ]; then
    echo "🖼️ Copying AppLogo.jpg..."
    cp Sources/errthang/Resources/AppLogo.jpg errthang.app/Contents/Resources/
fi

# 5.5 Copy SwiftPM resource bundle (optional, keeping for compatibility if needed)
if [ -d ".build/release/errthang_errthang.bundle" ]; then
    echo "📦 Copying resource bundle..."
    cp -R .build/release/errthang_errthang.bundle errthang.app/Contents/Resources/
fi

# 6. Set executable permissions
echo "🔐 Setting executable permissions..."
chmod +x errthang.app/Contents/MacOS/errthang

# 6.5 Code sign
echo "🔏 Code signing..."
codesign --force --deep --sign - errthang.app

# 7. Verify structure
echo "✅ Verifying .app structure..."
ls -la errthang.app/Contents/
echo ""
echo "📦 errthang.app package created successfully!"
echo "🚀 You can now run errthang.app from Applications"

rm -rf /Applications/errthang.app
mv errthang.app /Applications/
