// Draws Lounge Books' home-screen icons from the Lounge's own.
//
//   swift frontend/scripts/make-books-icons.swift
//
// The Lounge wordmark, shrunk into the top of the square, over a stack of
// three book spines in the wordmark's own orange, gold and brown — so the two
// icons sit side by side on a home screen as obviously the same family. Run
// from the repository root; it reads public/icon-512.png and writes the four
// books-*.png files beside it. Committed so the icons can be redrawn rather
// than hand-edited.

import AppKit
import CoreGraphics
import Foundation

let publicDir = URL(fileURLWithPath: "frontend/public")

func rgb(_ hex: UInt32) -> CGColor {
  CGColor(
    red: CGFloat((hex >> 16) & 0xff) / 255,
    green: CGFloat((hex >> 8) & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255,
    alpha: 1
  )
}

guard
  let source = NSImage(contentsOf: publicDir.appendingPathComponent("icon-512.png")),
  let wordmark = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  fatalError("Run from the repository root: frontend/public/icon-512.png not found")
}

// Draws the design into a square of `size`, with everything inside the
// central `content` fraction — 1 for a plain icon, 0.8 for a maskable one,
// whose outer ring a launcher may crop away.
func render(size: Int, content: CGFloat) -> CGImage {
  let s = CGFloat(size)
  let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.setFillColor(rgb(0xffffff))
  context.fill(CGRect(x: 0, y: 0, width: s, height: s))

  let box = s * content
  let origin = (s - box) / 2
  // Core Graphics counts y from the bottom.
  let unit = box / 512

  // The wordmark, in the top 56%.
  let markSize = 300 * unit
  context.interpolationQuality = .high
  context.draw(
    wordmark,
    in: CGRect(x: origin + (box - markSize) / 2, y: origin + box - markSize - 6 * unit, width: markSize, height: markSize)
  )

  // Three spines, bottom up, each with a darker band near either end like a
  // cloth binding, offset a little so the stack reads as hand-placed.
  let spines: [(width: CGFloat, height: CGFloat, dx: CGFloat, fill: UInt32, band: UInt32)] = [
    (360, 62, 0, 0x7c2d12, 0x5a1f0b),
    (320, 56, 14, 0xf97316, 0xc2410c),
    (290, 52, -10, 0xfacc15, 0xca8a04),
  ]
  var y = origin + 40 * unit
  for spine in spines {
    let width = spine.width * unit
    let height = spine.height * unit
    let x = origin + (box - width) / 2 + spine.dx * unit
    let rect = CGRect(x: x, y: y, width: width, height: height)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 8 * unit, cornerHeight: 8 * unit, transform: nil))
    context.setFillColor(rgb(spine.fill))
    context.fillPath()
    for bandX in [x + 26 * unit, x + width - 40 * unit] {
      context.setFillColor(rgb(spine.band))
      context.fill(CGRect(x: bandX, y: y, width: 14 * unit, height: height))
    }
    y += height + 6 * unit
  }

  return context.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
  let rep = NSBitmapImageRep(cgImage: image)
  let data = rep.representation(using: .png, properties: [:])!
  try! data.write(to: publicDir.appendingPathComponent(name))
  print("wrote frontend/public/\(name)")
}

write(render(size: 512, content: 1), "books-icon-512.png")
write(render(size: 192, content: 1), "books-icon-192.png")
write(render(size: 512, content: 0.8), "books-icon-512-maskable.png")
write(render(size: 180, content: 1), "books-apple-touch-icon.png")
