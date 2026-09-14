import AppKit

// =====================================================================
// The menu bar item's drawn indicator.
//
// It used to be a wide monospaced string ("⚡︎ 31%  🧠 73%") that ate ~90pt
// of menu bar. The island now carries the detail, so all the status item
// still needs is presence and a way into the menu: an 18pt two-bar meter.
//
// The RAM bar is the one that changes colour, and it only changes colour
// when the KERNEL says something is wrong — green is not used for
// "normal", because a permanently green light is noise. Normal is the
// same neutral label colour as the CPU bar; amber and red are the
// exceptions that earn attention.
// =====================================================================

enum StatusItemIcon {
    static let width: CGFloat = 18
    static let height: CGFloat = 15

    /// `cpu` and `ram` are 0...1, or nil for "could not measure" (drawn as
    /// an empty track, never as a fake zero fill).
    static func image(cpu: Double?, ram: Double?, pressure: MemoryPressureLevel?) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let barWidth: CGFloat = 6
            let gap: CGFloat = 4
            let x0: CGFloat = 1
            let x1 = x0 + barWidth + gap

            // NSColor.labelColor is dynamic; the drawing handler runs with
            // the destination's appearance current, so this tracks a light
            // or dark menu bar without us tracking it ourselves.
            let neutral = NSColor.labelColor
            let track = NSColor.labelColor.withAlphaComponent(0.16)

            let ramColor: NSColor
            switch pressure {
            case .warning: ramColor = NSColor.systemOrange
            case .critical: ramColor = NSColor.systemRed
            case .normal, nil: ramColor = neutral
            }

            drawBar(x: x0, width: barWidth, fraction: cpu, fill: neutral, track: track)
            drawBar(x: x1, width: barWidth, fraction: ram, fill: ramColor, track: track)
            return true
        }
        image.isTemplate = false      // the pressure colours are the point
        return image
    }

    private static func drawBar(x: CGFloat, width w: CGFloat, fraction: Double?,
                                fill: NSColor, track: NSColor) {
        let radius = w / 2
        let trackRect = NSRect(x: x, y: 1, width: w, height: height - 2)
        track.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius).fill()

        guard let fraction else { return }        // nil: leave the track empty
        let clamped = max(0, min(1, fraction))
        guard clamped > 0 else { return }
        // Keep a minimum nub so a tiny-but-nonzero value is still visible
        // as "something", without implying it is large.
        let h = max(w, trackRect.height * CGFloat(clamped))
        let fillRect = NSRect(x: x, y: 1, width: w, height: h)
        fill.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}
