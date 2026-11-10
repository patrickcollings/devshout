#!/usr/bin/env swift
// Draws devshout's app icon and writes the ten PNGs of the macOS icon set.
//
//   swift scripts/make-app-icon.swift
//
// The artwork is defined here and nowhere else: a blue-to-indigo rounded tile with white waveform bars that trail
// off into a full stop (voice in, text out). Change the numbers below, run the script, commit the PNGs.
//
// Layout follows Apple's macOS icon grid on a 1024 canvas: an 824 × 824 tile with a corner radius of about 185 and
// a soft shadow beneath it. All measurements below are in those 1024-canvas units. Each size is drawn on its own
// rather than scaled down from the big one, and the smallest sizes get fewer, thicker bars set on whole pixels.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let tileInset: CGFloat = 100
let tileRadiusRatio: CGFloat = 185.4 / 824

/// One white mark of the glyph: a capsule of the given height, or a dot when the height equals the width.
struct Glyph {
    var barWidth: CGFloat
    var gap: CGFloat
    var heights: [CGFloat]
}

/// 128 px and up: four bars and a closing dot.
let fullGlyph = Glyph(barWidth: 84, gap: 46, heights: [196, 372, 500, 288, 84])
/// 16 and 32 px: three bars. Every number is a multiple of 64, so edges land on whole pixels at 16 px.
let smallGlyph = Glyph(barWidth: 128, gap: 64, heights: [256, 512, 384])

func colour(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawIcon(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(pixels) / canvas
    let small = pixels <= 32
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    // Tile. At the small sizes its edge sits on a whole pixel so the outline stays crisp.
    let inset = small ? max(1, (tileInset * scale).rounded(.down)) / scale : tileInset
    let tile = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let radius = tile.width * tileRadiusRatio
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Shadow under the tile (the origin is bottom-left, so a negative y offset falls downwards).
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: colour(0x0B1040, alpha: 0.38)
    )
    context.addPath(tilePath)
    context.setFillColor(colour(0x3D5AF1))
    context.fillPath()
    context.restoreGState()

    // Background: bright blue at the top, indigo at the bottom.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: space,
        colors: [colour(0x38B6FF), colour(0x2F7BF6), colour(0x4B36D8)] as CFArray,
        locations: [0, 0.45, 1]
    )!
    context.drawLinearGradient(
        background, start: CGPoint(x: tile.midX - 120, y: tile.maxY), end: CGPoint(x: tile.midX + 120, y: tile.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    // A soft glow from the top-left corner gives the tile some depth.
    let glow = CGGradient(
        colorsSpace: space, colors: [colour(0xFFFFFF, alpha: 0.26), colour(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glow, startCenter: CGPoint(x: tile.minX + 180, y: tile.maxY - 60), startRadius: 0,
        endCenter: CGPoint(x: tile.minX + 180, y: tile.maxY - 60), endRadius: 700, options: []
    )
    context.restoreGState()

    // A hairline of light along the top edge, as on a lit surface. Too fine to help at the small sizes.
    if !small {
        context.saveGState()
        context.addPath(tilePath)
        context.clip()
        let line = max(4, 1.5 / scale)
        context.addPath(tilePath.copy(strokingWithWidth: line * 2, lineCap: .butt, lineJoin: .round, miterLimit: 1))
        context.clip()
        let rim = CGGradient(
            colorsSpace: space, colors: [colour(0xFFFFFF, alpha: 0.45), colour(0xFFFFFF, alpha: 0)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            rim, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.maxY - 300), options: []
        )
        context.restoreGState()
    }

    // The glyph, centred on the tile, with a faint shadow so the white sits on the gradient.
    let glyph = small ? smallGlyph : fullGlyph
    let count = CGFloat(glyph.heights.count)
    let totalWidth = count * glyph.barWidth + (count - 1) * glyph.gap
    var x = (canvas - totalWidth) / 2
    context.saveGState()
    if !small {
        context.setShadow(
            offset: CGSize(width: 0, height: -8 * scale), blur: 20 * scale, color: colour(0x1B1470, alpha: 0.35)
        )
    }
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(colour(0xFFFFFF))
    for height in glyph.heights {
        let bar = CGRect(x: x, y: (canvas - height) / 2, width: glyph.barWidth, height: height)
        // Fully rounded ends, except at 16 px where a 2 px bar is better left nearly square.
        let corner = pixels <= 16 ? glyph.barWidth / 4 : glyph.barWidth / 2
        context.addPath(CGPath(roundedRect: bar, cornerWidth: corner, cornerHeight: corner, transform: nil))
        x += glyph.barWidth + glyph.gap
    }
    context.fillPath()
    context.endTransparencyLayer()
    context.restoreGState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = repository.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")

var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try writePNG(drawIcon(pixels: points * factor), to: iconSet.appendingPathComponent(name))
        entries.append(
            "    { \"filename\" : \"\(name)\", \"idiom\" : \"mac\", \"scale\" : \"\(factor)x\", "
                + "\"size\" : \"\(points)x\(points)\" }"
        )
    }
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try contents.write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(entries.count) icons to \(iconSet.path)")
