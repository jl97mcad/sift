import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

let faceRect = NSRect(x: 96, y: 96, width: size - 192, height: size - 192)
let facePath = NSBezierPath(ovalIn: faceRect)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 40,
                  color: NSColor.black.withAlphaComponent(0.22).cgColor)
NSColor(calibratedRed: 0.71, green: 0.90, blue: 0.68, alpha: 1).setFill()
facePath.fill()
context.restoreGState()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.78, green: 0.94, blue: 0.73, alpha: 1),
    NSColor(calibratedRed: 0.63, green: 0.85, blue: 0.60, alpha: 1)
])
gradient?.draw(in: facePath, angle: -70)

NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.92, alpha: 1).setFill()
let eyeWidth: CGFloat = 118
let eyeHeight: CGFloat = 190
for x in [faceRect.midX - 150 - eyeWidth / 2, faceRect.midX + 150 - eyeWidth / 2] {
    let eye = NSRect(x: x, y: faceRect.midY - eyeHeight / 2 + 18, width: eyeWidth, height: eyeHeight)
    NSBezierPath(roundedRect: eye, xRadius: eyeWidth / 2, yRadius: eyeWidth / 2).fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }

let iconset = URL(fileURLWithPath: "Support/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for base in sizes {
    let scaled = NSImage(size: NSSize(width: base, height: base))
    scaled.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: base, height: base),
               from: NSRect(x: 0, y: 0, width: size, height: size),
               operation: .copy, fraction: 1)
    scaled.unlockFocus()
    guard let scaledTiff = scaled.tiffRepresentation,
          let scaledRep = NSBitmapImageRep(data: scaledTiff),
          let data = scaledRep.representation(using: .png, properties: [:]) else { continue }
    let name = base >= 1024 ? "icon_512x512@2x.png" : "icon_\(base)x\(base).png"
    try data.write(to: iconset.appendingPathComponent(name))
    if base == 32 { try data.write(to: iconset.appendingPathComponent("icon_16x16@2x.png")) }
    if base == 64 { try data.write(to: iconset.appendingPathComponent("icon_32x32@2x.png")) }
    if base == 256 { try data.write(to: iconset.appendingPathComponent("icon_128x128@2x.png")) }
    if base == 512 { try data.write(to: iconset.appendingPathComponent("icon_256x256@2x.png")) }
}
