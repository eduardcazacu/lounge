// Draws Lounge Books' home-screen icons from its wordmark.
//
//   swift frontend/scripts/make-books-icons.swift
//
// The "Books" wordmark, in the same extruded orange-and-brown lettering as the
// Lounge's own icon, centred on white with the same narrow margin, so the two
// sit side by side on a home screen as obviously the same family. The source
// art has a wide, uneven border, so it is cropped to the lettering before it is
// placed; the margin is then the icon's, not the drawing's. Run from the
// repository root; it reads scripts/books-wordmark.png, which is kept out of
// public/ so it is not deployed, and writes the four books-*.png files.

import AppKit
import CoreGraphics
import Foundation

let publicDir = URL(fileURLWithPath: "frontend/public")
let sourceURL = URL(fileURLWithPath: "frontend/scripts/books-wordmark.png")

guard
  let source = NSImage(contentsOf: sourceURL),
  let art = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  fatalError("Run from the repository root: frontend/scripts/books-wordmark.png not found")
}

// The bounding box of everything that is neither transparent nor near-white,
// in Core Graphics coordinates (y from the bottom).
func inkBounds(_ image: CGImage) -> CGRect {
  let w = image.width, h = image.height
  var pixels = [UInt8](repeating: 0, count: w * h * 4)
  let context = CGContext(
    data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: w, height: h))
  context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

  var minX = w, minY = h, maxX = -1, maxY = -1
  for row in 0..<h {
    for col in 0..<w {
      let i = (row * w + col) * 4
      if min(pixels[i], pixels[i + 1], pixels[i + 2]) < 235 {
        minX = min(minX, col); maxX = max(maxX, col)
        minY = min(minY, row); maxY = max(maxY, row)
      }
    }
  }
  // The buffer's first row is the top of the image.
  return CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let ink = inkBounds(art)

// Draws the design into a square of `size`, with the lettering inside the
// central `content` fraction — 0.92 for a plain icon, matching the Lounge's,
// and 0.72 for a maskable one, whose outer ring a launcher may crop away.
func render(size: Int, content: CGFloat) -> CGImage {
  let s = CGFloat(size)
  let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: s, height: s))

  let scale = s * content / max(ink.width, ink.height)
  let drawn = CGSize(width: ink.width * scale, height: ink.height * scale)
  // Draw the whole source, shifted so that its inked box lands centred.
  let origin = CGPoint(
    x: (s - drawn.width) / 2 - ink.minX * scale,
    y: (s - drawn.height) / 2 - ink.minY * scale
  )
  context.interpolationQuality = .high
  context.draw(
    art,
    in: CGRect(x: origin.x, y: origin.y, width: CGFloat(art.width) * scale, height: CGFloat(art.height) * scale)
  )
  return context.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
  let rep = NSBitmapImageRep(cgImage: image)
  let data = rep.representation(using: .png, properties: [:])!
  try! data.write(to: publicDir.appendingPathComponent(name))
  print("wrote frontend/public/\(name)")
}

write(render(size: 512, content: 0.92), "books-icon-512.png")
write(render(size: 192, content: 0.92), "books-icon-192.png")
write(render(size: 512, content: 0.72), "books-icon-512-maskable.png")
write(render(size: 180, content: 0.92), "books-apple-touch-icon.png")
