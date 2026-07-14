// make-icon.swift — renders the IJS Dashboard app icon (a bar chart on a warm
// rounded square) to a 1024×1024 PNG. Run via make-icon.sh. Standalone script.
import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Warm rounded-square background.
let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                             xRadius: 224, yRadius: 224)
if let gradient = NSGradient(
    starting: NSColor(calibratedRed: 1.0, green: 0.52, blue: 0.16, alpha: 1),
    ending: NSColor(calibratedRed: 0.92, green: 0.33, blue: 0.08, alpha: 1)) {
    gradient.draw(in: background, angle: -90)
} else {
    NSColor.orange.setFill()
    background.fill()
}

// White bar chart.
NSColor.white.setFill()
let heights: [CGFloat] = [0.38, 0.60, 0.82, 0.52]
let barWidth = size * 0.12
let gap = size * 0.065
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - totalWidth) / 2
let baseY = size * 0.27
for fraction in heights {
    let barHeight = size * 0.46 * fraction + size * 0.05
    NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barWidth, height: barHeight),
                 xRadius: 20, yRadius: 20).fill()
    x += barWidth + gap
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("make-icon: could not render PNG\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write(Data("make-icon: could not write \(outputPath): \(error)\n".utf8))
    exit(1)
}
