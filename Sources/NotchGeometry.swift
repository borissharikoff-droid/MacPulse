import AppKit

// =====================================================================
// Notch geometry.
//
// Portions of the NSScreen extension below are adapted from
// DynamicNotchKit — NSScreen+Extensions.swift, Created by Kai Azim on
// 2024-04-06 — which is distributed under the MIT licence:
//
//   MIT License
//   Copyright (c) 2024 Kai Azim
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to
//   the following conditions:
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
//
// https://github.com/MrKai77/DynamicNotchKit
//
// EVERY number here is derived at RUNTIME. Nothing about this machine's
// notch is hardcoded: an external display (no notch) or a resolution
// change has to keep working, and `NotchMetrics.detect` is a pure
// function precisely so it can be exercised with synthetic inputs.
// =====================================================================

extension NSScreen {
    /// True only on a display with a camera housing. BOTH auxiliary areas
    /// have to be present — they come back nil on external displays, and
    /// can come back nil *transiently* right after wake, which is why
    /// `IslandController` caches the last good metrics.
    var mp_hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0
            && auxiliaryTopLeftArea != nil
            && auxiliaryTopRightArea != nil
    }

    /// Menu bar height. 33.0 on macOS 26 here — deliberately NOT the same
    /// as the notch height (32.0). Sizing the island to this against a real
    /// notch leaves a 1pt ledge beside the physical glass.
    var mp_menubarHeight: CGFloat { frame.maxY - visibleFrame.maxY }

    var mp_displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var mp_isBuiltin: Bool {
        guard let id = mp_displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// Stable across reboots and display reordering. `NSScreen.screens`
    /// indices are not — they shuffle on dock/undock.
    var mp_displayUUID: String? {
        guard let id = mp_displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The screen the island should live on: the built-in panel (which is
    /// the only one that can have a notch), falling back to the main
    /// screen in clamshell.
    static var mp_islandScreen: NSScreen? {
        screens.first(where: { $0.mp_isBuiltin }) ?? main ?? screens.first
    }
}

// MARK: - Pure detection

/// Size and kind of the collapsed island body, derived from screen
/// geometry alone. A pure value type so it can be computed and checked
/// without a display attached.
struct NotchMetrics: Equatable {
    /// Pill dimensions used when there is no physical notch (external
    /// display, clamshell, a Mac without a camera housing).
    static let fallbackWidth: CGFloat = 180
    static let fallbackHeight: CGFloat = 32

    /// The black body that sits over/around the camera housing.
    let notchSize: CGSize
    let hasPhysicalNotch: Bool

    static func detect(screenFrame: CGRect,
                       safeAreaTop: CGFloat,
                       menubarHeight: CGFloat,
                       auxLeftWidth: CGFloat?,
                       auxRightWidth: CGFloat?) -> NotchMetrics {
        let l = auxLeftWidth ?? 0
        let r = auxRightWidth ?? 0
        guard safeAreaTop > 0, l > 0, r > 0 else {
            // Notchless fallback: a pill the height of the menu bar. The
            // caller floats it BELOW the menu bar rather than over it.
            return NotchMetrics(
                notchSize: CGSize(width: fallbackWidth,
                                  height: max(fallbackHeight, ceil(menubarHeight))),
                hasPhysicalNotch: false
            )
        }
        // The +4 is deliberate and is what boring.notch and ping-island both
        // do: the auxiliary areas measure to the ideal glass edge, and
        // without the fudge a 1-2px light seam shows at the notch sides.
        let w = max(fallbackWidth, ceil(screenFrame.width - l - r + 4))
        return NotchMetrics(notchSize: CGSize(width: w, height: ceil(safeAreaTop)),
                            hasPhysicalNotch: true)
    }

    static func detect(screen: NSScreen) -> NotchMetrics {
        detect(screenFrame: screen.frame,
               safeAreaTop: screen.safeAreaInsets.top,
               menubarHeight: screen.mp_menubarHeight,
               auxLeftWidth: screen.auxiliaryTopLeftArea?.width,
               auxRightWidth: screen.auxiliaryTopRightArea?.width)
    }
}

/// Screen-space rectangles for hit testing. Sendable and AppKit-free on
/// purpose — hit testing runs off `NSEvent.mouseLocation`, which is already
/// in global, bottom-left-origin screen coordinates.
struct NotchGeometry: Equatable, Sendable {
    let screenFrame: CGRect
    /// Body of the collapsed island (the part that overlaps the physical
    /// notch). `(183, 32)` on the MacBook Air M2.
    let notchSize: CGSize
    let hasPhysicalNotch: Bool
    /// How far below `screenFrame.maxY` the island's top edge sits. 0 on a
    /// notched display (flush with the glass); a small gap on the fallback
    /// pill so it floats under the menu bar instead of fighting it.
    let topInset: CGFloat

    init(screen: NSScreen, metrics: NotchMetrics) {
        self.screenFrame = screen.frame
        self.notchSize = metrics.notchSize
        self.hasPhysicalNotch = metrics.hasPhysicalNotch
        self.topInset = metrics.hasPhysicalNotch ? 0 : (screen.mp_menubarHeight + 6)
    }

    /// Island rect in screen coordinates for a drawn plate.
    ///
    /// THE ANCHOR IS THE CAMERA HOUSING, NOT THE PLATE. The housing is
    /// physical glass centred on `screenFrame.midX` and it does not move;
    /// the plate slides around it as the wings change size, which is what
    /// `centerOffsetX` carries. With equal wings the offset is 0 and this
    /// is the centred island that shipped before the wings became
    /// asymmetric.
    ///
    /// `IslandView` applies the same offset to the drawn shape. Both come
    /// from the same `IslandMetrics.Plate`, which is the only reason the
    /// hit rect cannot drift off the shape.
    func islandRect(_ plate: IslandMetrics.Plate) -> CGRect {
        CGRect(x: screenFrame.midX - plate.size.width / 2 + plate.centerOffsetX,
               y: screenFrame.maxY - topInset - plate.size.height,
               width: plate.size.width,
               height: plate.size.height)
    }

    /// Generous slop: the pointer skimming the very top edge of the screen
    /// (where it gets clamped) must still count as "in the notch".
    func hitRect(_ plate: IslandMetrics.Plate) -> CGRect {
        islandRect(plate).insetBy(dx: -10, dy: -6)
    }
}
