// =====================================================================
// MacPulse — the icon, drawn in code.
//
// This file is the SOURCE OF TRUTH for AppIcon.icns and for the DMG
// background. Nothing about the artwork is hand-placed pixels: run
// ./make-icon.sh and every size is regenerated from the maths below.
//
// Build/run:  ./make-icon.sh            (from the repo root)
// Directly:   swiftc -O -sdk <SDK> -target arm64-apple-macos13.0 \
//               -o /tmp/render-icon Tools/IconRender.swift
//             /tmp/render-icon icons --out Icon.iconset
//
// It lives in Tools/ and NOT in Sources/ on purpose: build.sh globs
// Sources/*.swift into the app binary, so a renderer parked there would
// be compiled into the shipping product (and would trip the contract
// guard's grep besides). Tools/ is outside that glob.
//
// ---------------------------------------------------------------------
// WHY THE SHAPE IS WHAT IT IS — every number below was MEASURED off
// Apple's own icons (macOS 26, /System/Applications/*/Contents/Resources/
// AppIcon.icns dumped with `iconutil -c iconset`), not guessed:
//
//   * BODY BOX. Notes/Calculator/Reminders/Console all put the opaque
//     body in a 0.8047 x 0.8047 box centred on the canvas — 824x824
//     inside 1024x1024, a 100pt transparent margin on every side. The
//     art does NOT bleed to the edge. (Measured: the 256pt renders have
//     a 205.7px body at a sub-pixel alpha threshold of 0.5.)
//
//   * CORNER. Fitting the measured alpha contour of Notes.app to a
//     rounded rect whose corners are the superellipse
//     (|x|/r)^n + (|y|/r)^n = 1 gives r = 0.2956 * side and n = 2.7,
//     with a residual seven times smaller than the best pure-superellipse
//     fit (n = 5.0). That is the "continuous curvature" squircle: the
//     corner is NOT a circular arc — a circle is n = 2 — and the sides
//     ARE dead straight through the middle ~41% of each edge. Getting
//     this wrong is the most obvious tell of a non-native icon.
//
//   * SURFACE. Console.app's graphite body is a top-down neutral ramp
//     from RGB 49 to RGB 20, with a ~5px-at-256 inner bevel that peaks
//     at RGB 144 on the top edge, 134 on the sides and 89 along the
//     bottom, and an ambient drop shadow whose maximum is alpha 33/255
//     (13%) one pixel under the bottom edge, gone by 10px. Those are
//     the numbers reproduced in `bodyRamp`, `bevel` and `shadow` below.
//
// ---------------------------------------------------------------------
// WHAT IT DEPICTS: the notch, and one glowing pressure dot — which is
// literally what the user looks at all day. MPNotchShape's concave top
// fillets are reproduced here exactly as Sources/NotchShape.swift draws
// them, so the icon and the running app are the same silhouette. The dot
// uses the REAL palette out of Sources/IslandViews.swift:
//
//     normal   0.30 0.83 0.42      warning  1.00 0.72 0.20
//     critical 1.00 0.36 0.32
//
// The shipping icon is the normal/green one; `--tint warning|critical`
// renders the same art in the other two, which is how you check that the
// composition survives a hue change (and how you'd make a screenshot of
// a machine in trouble).
//
// NO text, NO hairlines, NO gloss: at 16pt the body is 12.9px across and
// anything thinner than about 1.5px of it simply is not there.
// =====================================================================

import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - Colour

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

/// 0...255 sampled straight off a system icon, so the constants above can
/// be written the way they were measured.
func gray255(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor {
    rgb(v / 255, v / 255, v / 255, a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB,
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0})!
}

/// Pull a colour toward white. Used for the LED core, so the dot has a
/// hot centre instead of reading as a flat sticker.
func lighten(_ c: CGColor, _ t: CGFloat) -> CGColor {
    let k = c.components ?? [0, 0, 0, 1]
    return rgb(k[0] + (1 - k[0]) * t, k[1] + (1 - k[1]) * t, k[2] + (1 - k[2]) * t, k[3])
}

func fade(_ c: CGColor, _ a: CGFloat) -> CGColor {
    let k = c.components ?? [0, 0, 0, 1]
    return rgb(k[0], k[1], k[2], a)
}

// MARK: - The palette, copied from Sources/IslandViews.swift

enum Tint: String {
    case normal, warning, critical

    var color: CGColor {
        switch self {
        case .normal:   return rgb(0.30, 0.83, 0.42)
        case .warning:  return rgb(1.00, 0.72, 0.20)
        case .critical: return rgb(1.00, 0.36, 0.32)
        }
    }
}

// MARK: - Geometry (design units: a 1024 x 1024 canvas)

enum G {
    static let canvas: CGFloat = 1024

    /// 824 / 1024, measured off Notes.app. The transparent margin is the
    /// other 100 on each side and macOS relies on it — the Dock, Finder
    /// and Launchpad all draw their own separation assuming it is there.
    static let bodySide: CGFloat = 824
    static var body: CGRect {
        CGRect(x: (canvas - bodySide) / 2, y: (canvas - bodySide) / 2,
               width: bodySide, height: bodySide)
    }

    /// Corner box as a fraction of the side, and the superellipse
    /// exponent inside it. Both fitted to Apple's contour (see header).
    static let cornerExtent: CGFloat = 0.2956
    static let cornerExponent: CGFloat = 2.7

    // --- the notch ---------------------------------------------------
    /// Fractions OF THE BODY, not of the canvas. Wide and shallow, the
    /// way the real camera housing is: the first draft made it 0.62 tall
    /// and it stopped reading as a notch and started reading as a window
    /// cut in the middle of the icon.
    static let notchWidth: CGFloat = 0.620
    static let notchHeight: CGFloat = 0.215
    /// MPNotchShape's two radii, as fractions of the notch height. Taken
    /// from the running island's proportions: an ~8pt fillet and a ~13pt
    /// bottom round on a 32pt-tall strip.
    static let notchTopRadius: CGFloat = 0.280
    static let notchBottomRadius: CGFloat = 0.420

    // --- the pressure dot --------------------------------------------
    static let dotDiameter: CGFloat = 0.285      // of the body
    /// Centre, as a fraction of the body height below the body's top.
    /// Below the geometric middle on purpose: the notch is a block of
    /// mass at the top, and 0.50 left the icon looking like it was
    /// sliding upward out of its own square.
    static let dotCenterY: CGFloat = 0.560
}

// MARK: - Paths

/// The macOS squircle: straight edges, superelliptical corners.
///
/// Sampled as a dense polyline rather than approximated with two cubic
/// segments per corner — at 4096px (the supersampled master) a 160-point
/// quarter sweep is well under a tenth of a pixel of chord error, and it
/// means the fitted exponent is the ONLY knob. Authored y-down, matching
/// the flipped context set up in `render`.
func squircle(_ rect: CGRect,
              extent: CGFloat = G.cornerExtent,
              exponent n: CGFloat = G.cornerExponent) -> CGPath {
    let k = extent * min(rect.width, rect.height)
    let p = CGMutablePath()
    let steps = 160

    func sweep(_ inner: CGPoint, _ sx: CGFloat, _ sy: CGFloat, start: Bool) {
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * (.pi / 2)
            let u = pow(cos(t), 2 / n)
            let v = pow(sin(t), 2 / n)
            let pt = CGPoint(x: inner.x + sx * k * u, y: inner.y + sy * k * v)
            if start && i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
    }

    // top-left: from (minX, minY+k) round to (minX+k, minY)
    sweep(CGPoint(x: rect.minX + k, y: rect.minY + k), -1, -1, start: true)
    p.addLine(to: CGPoint(x: rect.maxX - k, y: rect.minY))
    // top-right: from (maxX-k, minY) round to (maxX, minY+k) — reversed sweep
    for i in stride(from: steps, through: 0, by: -1) {
        let t = CGFloat(i) / CGFloat(steps) * (.pi / 2)
        let u = pow(cos(t), 2 / n), v = pow(sin(t), 2 / n)
        p.addLine(to: CGPoint(x: rect.maxX - k + k * u, y: rect.minY + k - k * v))
    }
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - k))
    // bottom-right
    sweep(CGPoint(x: rect.maxX - k, y: rect.maxY - k), 1, 1, start: false)
    p.addLine(to: CGPoint(x: rect.minX + k, y: rect.maxY))
    // bottom-left — reversed
    for i in stride(from: steps, through: 0, by: -1) {
        let t = CGFloat(i) / CGFloat(steps) * (.pi / 2)
        let u = pow(cos(t), 2 / n), v = pow(sin(t), 2 / n)
        p.addLine(to: CGPoint(x: rect.minX + k - k * u, y: rect.maxY - k + k * v))
    }
    p.closeSubpath()
    return p
}

/// MPNotchShape, ported verbatim from Sources/NotchShape.swift (which is
/// itself vendored from DynamicNotchKit, MIT, (c) 2024 Kai Azim).
/// Authored top-left origin, y-down — same as the SwiftUI original, so
/// the two can be compared line for line.
func notchPath(_ rect: CGRect, topRadius tr: CGFloat, bottomRadius br: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                   control: CGPoint(x: rect.minX + tr, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
    p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                   control: CGPoint(x: rect.minX + tr, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                   control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                   control: CGPoint(x: rect.maxX - tr, y: rect.minY))
    p.closeSubpath()
    return p
}

// MARK: - Shadows
//
// CoreGraphics applies a shadow's offset and blur in BASE space — the
// context's device pixels — and NOT in the current user space. `render`
// below installs a flipped, scaled CTM, so a shadow written in design
// units comes out wrong twice over: it keeps a fixed pixel size while the
// art scales (so at 256px it is four times heavier, relative to the icon,
// than at 1024px), and a positive y offset LIFTS it instead of dropping
// it, because base space has y pointing up. Both bugs were in the first
// two drafts of this file and both were caught by sampling the render and
// comparing it with Console.app's measured profile — neither is visible
// by eye at 1024.
//
// This converts design units to base space, once, from the live CTM.
func shadow(_ ctx: CGContext, dy: CGFloat, blur: CGFloat, _ color: CGColor) {
    let scale = ctx.ctm.a                       // design unit -> device px
    ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale),
                  blur: blur * scale, color: color)
}

// MARK: - The icon

/// Apple's graphite ramp, straight off Console.app: 49 at the top of the
/// body down to 20 at the bottom. A hair of blue is added — two or three
/// units, invisible as a colour, enough that the surface reads as glass
/// rather than as newsprint.
let bodyRamp = gradient([
    (0.00, rgb(50 / 255, 51 / 255, 54 / 255)),
    (0.35, rgb(40 / 255, 41 / 255, 44 / 255)),
    (0.62, rgb(31 / 255, 32 / 255, 35 / 255)),
    (1.00, rgb(19 / 255, 20 / 255, 22 / 255)),
])

/// The inner bevel. Apple's is ~5px wide at 256pt — 20 design units —
/// and peaks at alpha 0.46 on the top edge, 0.29 along the bottom
/// (derived from the sampled RGB: (144-49)/(255-49) and (89-20)/(255-20)).
/// The `topAlpha`/`bottomAlpha` the caller passes are HIGHER than those
/// two numbers on purpose: the outermost strokes land on the
/// antialiased boundary and lose part of their coverage, so the asked-for
/// alpha has to be dialled up until the RENDERED pixels match. They were
/// tuned by sampling this renderer's 256px output against Console.app's,
/// not by arithmetic.
///
/// Drawn as a stack of ever-narrower strokes clipped inside the body, so
/// alpha accumulates toward the edge and decays inward on its own. The
/// step WIDTHS are spaced by a power law rather than evenly, because
/// even spacing makes the accumulated alpha decay linearly with depth
/// and Apple's does not: measured, it runs 0.46, 0.39, 0.25, 0.14,
/// 0.03, 0 at one-pixel-at-256 steps — a heavy head and a thin tail.
/// `falloff` = 1.5 reproduces that to within 0.05 alpha at every depth.
/// 1.0 leaves the tail too full (the edge light bleeds a fifth of the
/// way into the body and the whole icon looks airbrushed); 2.8 collapses
/// the entire ramp onto the outermost pixel and the edge turns hard.
func drawBevel(_ ctx: CGContext, path: CGPath, width: CGFloat,
               topAlpha: CGFloat, bottomAlpha: CGFloat, in rect: CGRect) {
    let steps = 40
    let falloff: CGFloat = 1.5
    func perStep(_ target: CGFloat) -> CGFloat { 1 - pow(1 - target, 1 / CGFloat(steps)) }
    let g = gradient([(0, gray255(255, perStep(topAlpha))),
                      (1, gray255(255, perStep(bottomAlpha)))])
    for i in 0..<steps {
        let half = width * pow(1 - CGFloat(i) / CGFloat(steps), falloff)
        guard half > 0.02 else { continue }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()                       // never spill outside the body
        ctx.addPath(path)
        ctx.setLineWidth(half * 2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: 0, y: rect.minY),
                               end: CGPoint(x: 0, y: rect.maxY),
                               options: [])
        ctx.restoreGState()
    }
}

func drawIcon(_ ctx: CGContext, tint: Tint) {
    let body = G.body
    let path = squircle(body)

    // --- drop shadow ------------------------------------------------
    // Apple's measured maximum is alpha 33/255 one pixel under the
    // bottom edge, 10/255 above the top one and 21/255 beside it, all
    // gone within 10px at 256pt: an ambient ring plus a small downward
    // bias, not a theatrical cast shadow.
    //
    // These two passes were FITTED to that, by rendering at 256 and
    // least-squares-ing the alpha profile below, above and beside the
    // body against Console.app's. The result is within one or two alpha
    // steps of Apple's at every sample:
    //
    //     below   33 33 27 21 16 11 7 4 2 1 0   (Apple: 33 33 27 21 15 11 7 5 3 2 1)
    //     above    0  0  0  2  3  6 9 14        (Apple:  0  0  1  2  3  5 8 10)
    ctx.saveGState()
    shadow(ctx, dy: 8, blur: 36, gray255(0, 0.22))       // directional
    ctx.addPath(path); ctx.setFillColor(gray255(0, 1)); ctx.fillPath()
    shadow(ctx, dy: 0, blur: 32, gray255(0, 0.06))       // ambient
    ctx.addPath(path); ctx.setFillColor(gray255(0, 1)); ctx.fillPath()
    ctx.restoreGState()

    // --- body surface ------------------------------------------------
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(bodyRamp,
                           start: CGPoint(x: 0, y: body.minY),
                           end: CGPoint(x: 0, y: body.maxY),
                           options: [])
    ctx.restoreGState()

    // --- the notch ---------------------------------------------------
    // Hangs from the body's top edge and is CLIPPED to the body, so the
    // two concave fillets die into the squircle's own curve exactly the
    // way the running island dies into the menu bar. Drawn flush at
    // body.minY: the body's top edge is straight to within a pixel out
    // to |x| = 210 and has only dropped ~5 units by |x| = 255, so the
    // clip takes a sliver off the outer tips and nothing more.
    let nw = G.notchWidth * body.width
    let nh = G.notchHeight * body.height
    let nrect = CGRect(x: body.midX - nw / 2, y: body.minY,
                       width: nw, height: nh)
    let npath = notchPath(nrect,
                          topRadius: G.notchTopRadius * nh,
                          bottomRadius: G.notchBottomRadius * nh)

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()        // the notch never leaves the body
    // A soft dark halo so the glass reads as recessed into the graphite
    // rather than pasted onto it. This is the only "lighting" in the
    // icon besides the bevel and the dot.
    shadow(ctx, dy: 5, blur: 16, gray255(0, 0.62))
    ctx.addPath(npath)
    ctx.setFillColor(gray255(7))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Barely-there vertical ramp on the glass itself: 12 -> 4.
    ctx.addPath(npath); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, gray255(12)), (1, gray255(4))]),
                           start: CGPoint(x: 0, y: nrect.minY),
                           end: CGPoint(x: 0, y: nrect.maxY),
                           options: [])
    ctx.restoreGState()

    // --- the pressure dot --------------------------------------------
    let d = G.dotDiameter * body.width
    let c = CGPoint(x: body.midX, y: body.minY + G.dotCenterY * body.height)
    let color = tint.color

    // The bloom. This is what keeps the icon alive at 16pt, where the dot
    // itself is only 3.9px across: the halo roughly doubles the lit area
    // so the eye finds it in a Finder list. It is clipped to the body —
    // a glow that escaped the squircle would be the sloppiest possible
    // tell — and it reaches up far enough to touch the notch, which is
    // what ties the two elements into one subject.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bloom = gradient([
        (0.00, fade(color, 0.40)),
        (0.34, fade(color, 0.22)),
        (0.68, fade(color, 0.07)),
        (1.00, fade(color, 0.00)),
    ])
    ctx.drawRadialGradient(bloom, startCenter: c, startRadius: d * 0.34,
                           endCenter: c, endRadius: d * 1.15,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // The LED itself: hot core, true palette colour at the rim. The core
    // is nudged up a fraction of a diameter so the light reads as coming
    // from above, like everything else in the icon.
    ctx.saveGState()
    let led = gradient([
        (0.00, lighten(color, 0.38)),
        (0.45, lighten(color, 0.10)),
        (1.00, color),
    ])
    ctx.addEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
    ctx.clip()
    ctx.drawRadialGradient(led,
                           startCenter: CGPoint(x: c.x, y: c.y - d * 0.16),
                           startRadius: 0,
                           endCenter: c, endRadius: d / 2,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // --- inner bevel, last, over everything --------------------------
    drawBevel(ctx, path: path, width: 20, topAlpha: 0.62, bottomAlpha: 0.37, in: body)
}

// MARK: - Rendering

/// Everything is drawn in the 1024-unit design space and scaled; the
/// context is flipped so y grows DOWNWARD, which is the space
/// Sources/NotchShape.swift is authored in.
func render(pixels: Int, supersample: Int = 4, _ draw: (CGContext, CGFloat) -> Void) -> CGImage {
    let big = pixels * supersample
    let ctx = CGContext(data: nil, width: big, height: big,
                        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: CGFloat(big))
    ctx.scaleBy(x: 1, y: -1)
    let s = CGFloat(big) / G.canvas
    ctx.scaleBy(x: s, y: s)
    draw(ctx, G.canvas)
    let master = ctx.makeImage()!
    guard supersample > 1 else { return master }
    // Downsample the 4x master rather than rasterising the vectors at
    // 16px: CG's own edge antialiasing at that size loses the bloom.
    let out = CGContext(data: nil, width: pixels, height: pixels,
                        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    out.interpolationQuality = .high
    out.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return out.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write("cannot create \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("cannot write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - The DMG background
//
// 640 x 400 at 1x and 1280 x 800 at 2x, both in one .tiff-free pair of
// PNGs (Finder picks the @2x automatically when the volume's .DS_Store
// names the 1x file and the @2x sits beside it).
//
// The icon positions the window layout MUST use are in
// dmg-assets/dmg-layout.txt — the arrow drawn here points from one to
// the other and will look wrong if they move.

enum DMG {
    static let width: CGFloat = 640
    static let height: CGFloat = 400
    static let appSlot = CGPoint(x: 168, y: 208)     // Finder icon centres,
    static let appsSlot = CGPoint(x: 472, y: 208)    // origin top-left
}

/// The system UI font at a given weight. `CTFontCreateUIFontForLanguage`
/// is documented as returning an optional and there is no useful recovery
/// from it failing, but crashing a build script over a font is worse than
/// setting the line in Helvetica.
func uiFont(_ size: CGFloat, weight: CGFloat) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let desc = CTFontDescriptorCreateCopyWithAttributes(
        CTFontCopyFontDescriptor(base),
        [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]] as CFDictionary)
    return CTFontCreateWithFontDescriptor(desc, size, nil)
}

func drawText(_ ctx: CGContext, _ string: String, size: CGFloat, weight: CGFloat,
              color: CGColor, center: CGPoint) {
    let font = uiFont(size, weight: weight)
    let attr = NSAttributedString(string: string, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: color,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: 1, y: -1)             // undo the y-down flip for text
    ctx.textPosition = CGPoint(x: -bounds.width / 2 - bounds.minX,
                               y: -bounds.height / 2 - bounds.minY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func drawDMG(_ ctx: CGContext) {
    let r = CGRect(x: 0, y: 0, width: DMG.width, height: DMG.height)

    // Field: the same graphite as the icon, so the window and the thing
    // being installed are obviously the same object.
    ctx.saveGState()
    ctx.addRect(r); ctx.clip()
    ctx.drawLinearGradient(gradient([
        (0.00, rgb(36 / 255, 38 / 255, 42 / 255)),
        (0.55, rgb(28 / 255, 30 / 255, 33 / 255)),
        (1.00, rgb(20 / 255, 21 / 255, 23 / 255)),
    ]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: DMG.height), options: [])

    // A single soft pool of light behind the drop target. No vignette
    // ring, no texture.
    ctx.drawRadialGradient(gradient([
        (0.0, gray255(255, 0.055)),
        (1.0, gray255(255, 0.0)),
    ]), startCenter: CGPoint(x: DMG.width / 2, y: 196), startRadius: 0,
       endCenter: CGPoint(x: DMG.width / 2, y: 196), endRadius: 320, options: [])
    ctx.restoreGState()

    // Header: the icon itself at 56pt, with the name beside it.
    let mark: CGFloat = 56
    let title = "MacPulse"
    let titleSize: CGFloat = 26
    // Measure the title so icon+gap+title can be centred as one group.
    let probeAttr = NSAttributedString(string: title, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: uiFont(titleSize, weight: 0.23),
    ])
    let titleWidth = CTLineGetBoundsWithOptions(
        CTLineCreateWithAttributedString(probeAttr), .useOpticalBounds).width
    let gap: CGFloat = 16
    let groupWidth = mark + gap + titleWidth
    let groupX = (DMG.width - groupWidth) / 2
    let headerY: CGFloat = 62

    ctx.saveGState()
    // The icon art is authored on a 1024 canvas; drop it in at `mark` pt.
    ctx.translateBy(x: groupX, y: headerY - mark / 2)
    let k = mark / G.canvas
    ctx.scaleBy(x: k, y: k)
    drawIcon(ctx, tint: .normal)
    ctx.restoreGState()

    drawText(ctx, title, size: titleSize, weight: 0.23,
             color: gray255(255, 0.93),
             center: CGPoint(x: groupX + mark + gap + titleWidth / 2, y: headerY))

    // The arrow. A tapered stem and a solid head, both flat white at low
    // alpha — no gradient, no outline, nothing that reads as clip art.
    let y = DMG.appSlot.y
    let x0 = DMG.appSlot.x + 100
    let x1 = DMG.appsSlot.x - 100
    let headLen: CGFloat = 32
    let headHalf: CGFloat = 19
    let stemHalf: CGFloat = 5.0
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: x0, y: y - stemHalf))
    arrow.addLine(to: CGPoint(x: x1 - headLen, y: y - stemHalf))
    arrow.addLine(to: CGPoint(x: x1 - headLen, y: y - headHalf))
    arrow.addLine(to: CGPoint(x: x1, y: y))
    arrow.addLine(to: CGPoint(x: x1 - headLen, y: y + headHalf))
    arrow.addLine(to: CGPoint(x: x1 - headLen, y: y + stemHalf))
    arrow.addLine(to: CGPoint(x: x0, y: y + stemHalf))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.setFillColor(gray255(255, 0.38))
    ctx.fillPath()

    drawText(ctx, "Перетащите MacPulse в папку Applications",
             size: 13, weight: 0.0, color: gray255(255, 0.42),
             center: CGPoint(x: DMG.width / 2, y: 336))
}

func renderDMG(scale: Int) -> CGImage {
    let w = Int(DMG.width) * scale, h = Int(DMG.height) * scale
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.setShouldSmoothFonts(true)
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    drawDMG(ctx)
    return ctx.makeImage()!
}

// MARK: - CLI

func arg(_ name: String, default def: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--" + name), i + 1 < a.count { return a[i + 1] }
    return def
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons"
let tint = Tint(rawValue: arg("tint", default: "normal")) ?? .normal
let outDir = URL(fileURLWithPath: arg("out", default: "Icon.iconset"))
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

switch mode {
case "icons":
    // The ten entries macOS wants. Seven distinct rasters; the three
    // duplicated pixel sizes are rendered once and written twice.
    let entries: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    var cache: [Int: CGImage] = [:]
    for (name, px) in entries {
        let image = cache[px] ?? render(pixels: px) { ctx, _ in drawIcon(ctx, tint: tint) }
        cache[px] = image
        write(image, to: outDir.appendingPathComponent(name))
        print("   \(name)  \(px)x\(px)")
    }

case "preview":
    // Loose PNGs at whatever sizes, for eyeballing during design work.
    let sizes = arg("sizes", default: "1024,256,128,32,16")
        .split(separator: ",").compactMap { Int($0) }
    for px in sizes {
        let image = render(pixels: px) { ctx, _ in drawIcon(ctx, tint: tint) }
        write(image, to: outDir.appendingPathComponent("preview-\(tint.rawValue)-\(px).png"))
        print("   preview-\(tint.rawValue)-\(px).png")
    }

case "dmg":
    write(renderDMG(scale: 1), to: outDir.appendingPathComponent("dmg-background.png"))
    write(renderDMG(scale: 2), to: outDir.appendingPathComponent("dmg-background@2x.png"))
    print("   dmg-background.png       640x400")
    print("   dmg-background@2x.png   1280x800")

default:
    FileHandle.standardError.write("usage: render-icon [icons|preview|dmg] --out DIR [--tint normal|warning|critical]\n".data(using: .utf8)!)
    exit(2)
}
