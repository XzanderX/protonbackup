.PHONY: build run test clean generate-xcodeproj package dev-build

# Development build using Swift Package Manager (faster, no extension)
dev-build:
	swift build

# Run the app (development)
run:
	swift run Neutrony

# Run tests
test:
	swift test

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build DerivedData build Neutrony.xcodeproj

# Generate Xcode project using XcodeGen (requires: brew install xcodegen)
generate-xcodeproj:
	xcodegen generate

# Build release with Xcode (includes FinderSync extension)
release: generate-xcodeproj
	xcodebuild -project Neutrony.xcodeproj -scheme Neutrony -configuration Release -derivedDataPath build/DerivedData build

# Package as .app bundle (includes FinderSync extension)
package: release
	@echo "Creating app bundle with FinderSync extension..."
	@rm -rf build/Neutrony.app
	@cp -R build/DerivedData/Build/Products/Release/Neutrony.app build/
	@echo ""
	@echo "========================================="
	@echo "App bundle created at build/Neutrony.app"
	@echo "========================================="
	@echo ""
	@echo "The app includes the FinderSync extension for Finder badges."
	@echo "On first run, the app will prompt you to enable it."
	@echo ""
	@echo "To run: open build/Neutrony.app"
