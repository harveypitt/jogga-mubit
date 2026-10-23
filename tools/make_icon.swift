// Generates the 1024x1024 app icon: ember gradient, white rounded "j" glyph.
import AppKit

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

let rect = CGRect(origin: .zero, size: size)

// Ember gradient background (subtle, top-left light to bottom-right deep).
let colors = [
    NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.28, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.16, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])

// White rounded "j" glyph drawn as a stroked path: dot + hooked stem.
let white = NSColor.white.cgColor
ctx.setStrokeColor(white)
ctx.setFillColor(white)
ctx.setLineWidth(120)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Stem: from upper right, down, hooking left at the bottom.
let path = CGMutablePath()
path.move(to: CGPoint(x: 640, y: 700))
path.addLine(to: CGPoint(x: 640, y: 360))
path.addQuadCurve(to: CGPoint(x: 430, y: 330), control: CGPoint(x: 640, y: 300))
ctx.addPath(path)
ctx.strokePath()

// Dot above the stem.
ctx.fillEllipse(in: CGRect(x: 640 - 62, y: 830 - 62, width: 124, height: 124))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
