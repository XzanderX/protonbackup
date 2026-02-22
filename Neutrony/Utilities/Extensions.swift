import Foundation
import SwiftUI

// MARK: - Date Extensions

extension Date {
    /// Format as relative time string (e.g., "5 minutes ago").
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    /// Format as a short date-time string.
    var shortString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

// MARK: - Optional Extensions

extension Optional where Wrapped == String {
    /// Returns true if the string is nil or empty.
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}

// MARK: - View Extensions

extension View {
    /// Apply a modifier only if a condition is true.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Color Extensions

extension Color {
    static let protonPurple = Color(red: 0.42, green: 0.27, blue: 0.83)
    static let protonPurpleLight = Color(red: 0.55, green: 0.41, blue: 0.92)
    static let statusGreen = Color(red: 0.2, green: 0.78, blue: 0.35)
    static let statusYellow = Color(red: 0.95, green: 0.77, blue: 0.06)
    static let statusRed = Color(red: 0.94, green: 0.27, blue: 0.27)
}

// MARK: - String Path Sanitization

extension String {
    /// Replace characters that are invalid on common backup-destination filesystems (exFAT, FAT32, NTFS).
    /// Applied to destination paths only — source paths must remain unsanitized to match the original files.
    func sanitizedForExternalVolume() -> String {
        // Characters forbidden on exFAT/FAT32/NTFS: " * : < > ? \ |
        // Forward slash is a path separator so we must not touch it.
        let table: [Character: Character] = [
            "\"": "'",
            "*": "_",
            "<": "(",
            ">": ")",
            "?": "_",
            "\\": "-",
            "|": "-",
            ":": "-",
        ]
        var result = ""
        result.reserveCapacity(count)
        for ch in self {
            if let replacement = table[ch] {
                result.append(replacement)
            } else {
                result.append(ch)
            }
        }
        return result
    }
}

// MARK: - Int64 Extensions

extension Int64 {
    /// Format as a file size string.
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
