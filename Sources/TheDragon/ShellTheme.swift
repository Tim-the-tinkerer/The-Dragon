import AppKit
import SwiftUI

enum ShellTheme {
    static let ink = Color(red: 0.09, green: 0.07, blue: 0.06)
    static let lift = Color(red: 0.14, green: 0.11, blue: 0.09)
    static let paper = Color(red: 0.18, green: 0.14, blue: 0.11)
    static let brass = Color(red: 0.86, green: 0.68, blue: 0.36)
    static let cream = Color(red: 0.95, green: 0.91, blue: 0.82)
    static let muted = Color(red: 0.72, green: 0.64, blue: 0.50)
    static let dim = Color(red: 0.48, green: 0.42, blue: 0.34)

    static var windowNS: NSColor {
        NSColor(srgbRed: 0.09, green: 0.07, blue: 0.06, alpha: 1)
    }
}
