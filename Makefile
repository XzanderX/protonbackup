.PHONY: build run test clean generate-xcodeproj package xcode-build

# Build using Swift Package Manager (main app only, no extension)
build:
	swift build

# Build release (main app only, no extension)
release:
	swift build -c release

# Run the app (development)
run:
	swift run Neutrony

# Run tests
test:
	swift test

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build DerivedData build

# Generate Xcode project using XcodeGen (requires: brew install xcodegen)
generate-xcodeproj:
	xcodegen generate

# Build with Xcode (required for FinderSync extension)
xcode-build: generate-xcodeproj
	xcodebuild -project Neutrony.xcodeproj -scheme Neutrony -configuration Release build

# Package as .app bundle (without FinderSync extension - use xcode-package for full build)
package: release
	@echo "Creating app bundle..."
	@rm -rf build/Neutrony.app
	@mkdir -p build/Neutrony.app/Contents/MacOS
	@mkdir -p build/Neutrony.app/Contents/Resources
	@cp .build/release/Neutrony build/Neutrony.app/Contents/MacOS/
	@cp Neutrony/Info.plist build/Neutrony.app/Contents/
	@echo "Ad-hoc signing app bundle..."
	@codesign --force --deep --sign - build/Neutrony.app
	@echo "App bundle created at build/Neutrony.app"
	@echo "Note: This build does NOT include the FinderSync extension."
	@echo "For full build with Finder badges, use: make xcode-package"

# Package with Xcode (includes FinderSync extension)
xcode-package: generate-xcodeproj
	@echo "Building with Xcode (includes FinderSync extension)..."
	xcodebuild -project Neutrony.xcodeproj -scheme Neutrony -configuration Release -derivedDataPath build/DerivedData build
	@rm -rf build/Neutrony.app
	@cp -R build/DerivedData/Build/Products/Release/Neutrony.app build/
	@echo "App bundle with FinderSync extension created at build/Neutrony.app"
	@echo "To enable Finder badges:"
	@echo "  1. Open System Settings > Privacy & Security > Extensions > Added Extensions"
	@echo "  2. Enable 'Proton Backup Finder Extension' under Finder"
