import AppKit

// Generates a 1024×1024 app icon PNG: gradient rounded square + white music glyph.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let clip = NSBezierPath(roundedRect: rect, xRadius: 224, yRadius: 224)
clip.addClip()

let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.49, green: 0.31, blue: 0.97, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.98, alpha: 1),
])!
grad.draw(in: rect, angle: -90)

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    let r = NSRect(origin: .zero, size: image.size)
    image.draw(in: r)
    r.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

let glyphSize: CGFloat = 560
let cfg = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
if let base = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let white = tinted(base, .white)
    let s = white.size
    let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
    white.draw(at: origin, from: NSRect(origin: .zero, size: s),
               operation: .sourceOver, fraction: 0.96)
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
