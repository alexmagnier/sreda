// mkicon.swift OUT.png SYMBOL R G B — rounded-square app icon with a white SF Symbol (macOS icon grid)
import AppKit
let a = CommandLine.arguments
let out = a[1], sym = a[2]
let col = NSColor(srgbRed: CGFloat(Double(a[3])!/255), green: CGFloat(Double(a[4])!/255), blue: CGFloat(Double(a[5])!/255), alpha: 1)
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let inset: CGFloat = 100
let r = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let path = NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185)
let g = NSGradient(starting: col.blended(withFraction: 0.25, of: .white)!, ending: col.blended(withFraction: 0.2, of: .black)!)!
g.draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold).applying(.init(paletteColors: [.white]))
if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = img.size
    img.draw(in: NSRect(x: (size - s.width)/2, y: (size - s.height)/2, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
