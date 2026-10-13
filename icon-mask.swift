import AppKit
import SwiftUI
// Puts the full-bleed artwork into Apple's icon shape: an 824-point continuous
// rounded square centered on a 1024 canvas, the size macOS expects.
let art = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
cg.addPath(RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: rect).cgPath)
cg.clip()
art.draw(in: rect)
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
