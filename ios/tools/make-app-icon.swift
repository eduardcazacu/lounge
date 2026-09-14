// Renders the App Store icon: Instant's bolt, the mark on the sign-in screen,
// on the app's near-black ground.
//
//   xcrun swift ios/tools/make-app-icon.swift
//
// Writes Instant/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png, a
// 1024x1024 PNG with no alpha channel — App Store Connect rejects an icon with
// transparency. iOS applies the rounded mask itself, so the square is full-bleed.
// Replace the PNG with a designed icon whenever there is one; nothing else
// refers to this script.

import AppKit

let size = 1024
let output = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../Instant/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    .standardizedFileURL

// An RGB context that skips alpha: AppKit will not draw into an alpha-less
// NSBitmapImageRep at all (every draw is silently a no-op), but Core Graphics
// will, and the image it produces carries no alpha channel.
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Could not create the drawing context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let canvas = NSRect(x: 0, y: 0, width: size, height: size)

// Ground: the app's black, lifted slightly toward the top so the mark does not
// sit on a flat void.
NSGradient(colors: [
    NSColor(calibratedWhite: 0.16, alpha: 1),
    NSColor(calibratedWhite: 0.02, alpha: 1),
])!.draw(in: canvas, angle: -90)

// A soft amber glow behind the bolt, in Instant's streak-flame colour.
let flame = NSColor(calibratedRed: 0xF5 / 255.0, green: 0x9E / 255.0, blue: 0x0B / 255.0, alpha: 1)
// Unclipped and fading all the way to nothing, so it has no edge.
let center = NSPoint(x: canvas.midX, y: canvas.midY)
NSGradient(colors: [flame.withAlphaComponent(0.38), flame.withAlphaComponent(0)])!
    .draw(fromCenter: center, radius: 0, toCenter: center, radius: 470, options: [])

// The bolt itself, white, as on the sign-in screen.
let configuration = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
guard let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration)
else {
    fatalError("bolt.fill is not available on this Mac")
}
let boltSize = bolt.size
bolt.draw(
    in: NSRect(
        x: (CGFloat(size) - boltSize.width) / 2,
        y: (CGFloat(size) - boltSize.height) / 2,
        width: boltSize.width,
        height: boltSize.height
    )
)

NSGraphicsContext.restoreGraphicsState()

guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else {
    fatalError("Could not encode the PNG")
}
try png.write(to: output)
print("Wrote \(output.path) (\(size)x\(size), no alpha)")
