import AppKit

// Draws the Project Vault app icon (a white lock on an indigo rounded square) as a 1024px PNG.
let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.31, green: 0.42, blue: 0.95, alpha: 1),
           ending: NSColor(calibratedRed: 0.17, green: 0.23, blue: 0.66, alpha: 1))!.draw(in: bg, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
if let sym = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let r = NSRect(x: (size - sym.size.width) / 2, y: (size - sym.size.height) / 2 - 10,
                   width: sym.size.width, height: sym.size.height)
    tinted.draw(in: r)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
