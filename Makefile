.PHONY: build run test clean generate-xcodeproj package

# Build using Swift Package Manager
build:
	swift build

# Build release
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
	rm -rf .build DerivedData

# Generate Xcode project using XcodeGen (requires: brew install xcodegen)
generate-xcodeproj:
	xcodegen generate

# Package as .app bundle
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
	@echo "To open: open build/Neutrony.app"
	@echo "For distribution, re-sign with: codesign --deep --force --sign 'Developer ID Application: ...' build/Neutrony.app"
