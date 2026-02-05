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
	@rm -rf build/ProtonBackup.app
	@mkdir -p build/ProtonBackup.app/Contents/MacOS
	@mkdir -p build/ProtonBackup.app/Contents/Resources
	@cp .build/release/ProtonBackup build/ProtonBackup.app/Contents/MacOS/
	@cp ProtonBackup/Info.plist build/ProtonBackup.app/Contents/
	@echo "Ad-hoc signing app bundle..."
	@codesign --force --deep --sign - build/ProtonBackup.app
	@echo "App bundle created at build/ProtonBackup.app"
	@echo "To open: open build/ProtonBackup.app"
	@echo "For distribution, re-sign with: codesign --deep --force --sign 'Developer ID Application: ...' build/ProtonBackup.app"
