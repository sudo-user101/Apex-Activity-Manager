import AppKit
import SwiftUI

/// The memory palette: one colour per memory figure, the same in the graph,
/// its legend, the breakdown and tooltips. Blue is RAM in use; yellow and red
/// only ever mean memory pressure. Each has a lighter shade for Dark Mode and
/// a deeper one for Light Mode, so it stays readable on its background.
enum MemoryColor {
    static let used = dynamic(dark: 0x4C9AFF, light: 0x1F6FDB)
    static let apps = dynamic(dark: 0x7C83FF, light: 0x5158D6)
    static let system = dynamic(dark: 0x42C7D5, light: 0x138A99)
    static let compressed = dynamic(dark: 0xB38AFF, light: 0x8256D4)
    static let cache = dynamic(dark: 0x8E949C, light: 0x9AA0A8)
    static let available = dynamic(dark: 0x4CCBA0, light: 0x1B8F68)
    static let swap = dynamic(dark: 0xFF9F43, light: 0xC86E12)
    /// Free memory is what's left: the bar's empty track, a quiet grey elsewhere.
    static let free = dynamic(dark: 0x9AA0A6, light: 0x80868C)
    static let elevated = dynamic(dark: 0xF5C542, light: 0xB38600)
    static let critical = dynamic(dark: 0xFF5C5C, light: 0xD13434)
    /// Normal pressure: a calm green, apart from Available's mint.
    static let normal = dynamic(dark: 0x6CC57C, light: 0x2E8B45)

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// How RAM divides up, as macOS counts it: used = apps + operating system
/// (wired) + compressed; cache is reclaimable and counts as available; free
/// is the rest. These don't overlap, so they can share one bar. Pure: tested.
enum MemoryComposition {
    static func parts(_ m: MemoryStats) -> [(MemSeries, UInt64)] {
        [(.apps, m.app), (.system, m.wired), (.compressed, m.compressed), (.cache, m.cached)]
    }

    static func free(_ m: MemoryStats) -> UInt64 {
        m.total > m.used + m.cached ? m.total - m.used - m.cached : 0
    }
}
