import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png",16), ("icon_16x16@2x.png",32),
    ("icon_32x32.png",32), ("icon_32x32@2x.png",64),
    ("icon_128x128.png",128), ("icon_128x128@2x.png",256),
    ("icon_256x256.png",256), ("icon_256x256@2x.png",512),
    ("icon_512x512.png",512), ("icon_512x512@2x.png",1024)
]
for (name, size) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size) / 1024); transform.concat()
    let base = NSBezierPath(roundedRect: CGRect(x: 94,y: 94,width: 836,height: 836), xRadius: 182,yRadius: 182)
    NSGradient(starting: NSColor(calibratedRed:0.25,green:0.29,blue:0.35,alpha:1),
               ending: NSColor(calibratedRed:0.12,green:0.15,blue:0.20,alpha:1))!.draw(in: base, angle: -90)
    NSColor.white.withAlphaComponent(0.11).setFill()
    NSBezierPath(roundedRect: CGRect(x: 211,y: 273,width: 602,height: 190), xRadius: 50,yRadius: 50).fill()
    let cards: [(CGFloat, CGFloat)] = [(281,220),(429,320),(577,260)]
    for (x,height) in cards {
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: CGRect(x:x,y:363,width:123,height:height),xRadius:27,yRadius:27).fill()
    }
    NSColor.white.setFill()
    NSBezierPath(roundedRect: CGRect(x: 275,y: 294,width: 474,height: 39), xRadius:20,yRadius:20).fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: destination.appendingPathComponent(name))
}
