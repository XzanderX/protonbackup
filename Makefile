.PHONY: build run test clean generate-xcodeproj package

# Build using Swift Package Manager
build:
	swift build

# Build release
release:
	swift build -c release

# Run the app (development)
run:
	swift run ProtonBackup

# Run tests
test:
	swift test

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build DerivedData

# Generate Xcode project using XcodeGen (requires: brew install xcodegen)
generate-xcodeproj:
	xcodegen generate

# Package as .app bundle
package: release
	@echo "Creating app bundle..."
	@mkdir -p build/ProtonBackup.app/Contents/MacOS
	@mkdir -p build/ProtonBackup.app/Contents/Resources
	@cp .build/release/ProtonBackup build/ProtonBackup.app/Contents/MacOS/
	@cp ProtonBackup/Info.plist build/ProtonBackup.app/Contents/
	@echo "App bundle created at build/ProtonBackup.app"
	@echo "Note: For distribution, sign with: codesign --deep --force --sign 'Developer ID' build/ProtonBackup.app"
