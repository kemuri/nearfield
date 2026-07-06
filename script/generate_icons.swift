#!/usr/bin/env swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let optionsDir = root.appendingPathComponent("Assets/IconOptions", isDirectory: true)
let nearfieldOptionDir = optionsDir.appendingPathComponent("nearfield", isDirectory: true)
let resourcesDir = root.appendingPathComponent("Sources/Nearfield/Resources/Icons", isDirectory: true)
let driverResourcesDir = root.appendingPathComponent("Vendor/app-router-audio-device/proxyAudioDevice", isDirectory: true)
let nearfieldIconSVG = root.appendingPathComponent("Assets/nearfield.icon/Assets/SVG Image.svg")
let menuBarSVG = root.appendingPathComponent("Assets/menubar.svg")

try FileManager.default.createDirectory(at: nearfieldOptionDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

func image(size: Int, draw: (CGFloat) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGFloat(size))
    image.unlockFocus()
    return image
}

func pngData(_ image: NSImage) -> Data {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else { fatalError("Unable to render PNG") }
    return data
}

func writePNG(_ image: NSImage, to url: URL) throws {
    try pngData(image).write(to: url)
}

func svgImage(from url: URL, fill: String) throws -> NSImage {
    let source = try String(contentsOf: url, encoding: .utf8)
    let tintedSource = source.replacingOccurrences(of: #"fill="white""#, with: #"fill="\#(fill)""#)
    guard let data = tintedSource.data(using: .utf8),
          let image = NSImage(data: data) else {
        fatalError("Unable to load SVG at \(url.path)")
    }
    return image
}

func makeICNS(from iconset: URL, output: URL) throws {
    try? FileManager.default.removeItem(at: output)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["--convert", "icns", iconset.path, "--output", output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("iconutil failed for \(iconset.path)")
    }
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawNearfieldAppIcon(size: Int) -> NSImage {
    image(size: size) { s in
        let rect = CGRect(x: 0, y: 0, width: s, height: s)
        let background = roundedRect(rect.insetBy(dx: s * 0.045, dy: s * 0.045), radius: s * 0.22)

        NSGraphicsContext.saveGraphicsState()
        background.addClip()
        NSGradient(
            starting: NSColor(calibratedWhite: 0.98, alpha: 1),
            ending: NSColor(calibratedWhite: 0.82, alpha: 1)
        )?.draw(in: rect, angle: 90)
        NSColor.white.withAlphaComponent(0.42).setFill()
        NSBezierPath(ovalIn: CGRect(x: -s * 0.20, y: s * 0.54, width: s * 0.70, height: s * 0.48)).fill()
        NSColor.black.withAlphaComponent(0.05).setFill()
        NSBezierPath(ovalIn: CGRect(x: s * 0.48, y: -s * 0.12, width: s * 0.58, height: s * 0.48)).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.12).setStroke()
        background.lineWidth = max(1, s * 0.006)
        background.stroke()

        guard let mark = try? svgImage(from: nearfieldIconSVG, fill: "#050505") else {
            fatalError("Missing Nearfield app icon SVG")
        }
        draw(mark: mark, in: CGRect(x: 0, y: 0, width: s, height: s), widthScale: 0.64, yOffset: -s * 0.015)
    }
}

func drawNearfieldDeviceIcon(size: Int) -> NSImage {
    image(size: size) { s in
        NSColor.clear.setFill()
        CGRect(x: 0, y: 0, width: s, height: s).fill()

        guard let mark = try? svgImage(from: menuBarSVG, fill: "#ffffff") else {
            fatalError("Missing Nearfield menubar SVG")
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.70)
        shadow.shadowBlurRadius = s * 0.028
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
        draw(mark: mark, in: CGRect(x: 0, y: 0, width: s, height: s), widthScale: 0.82)
    }
}

func draw(mark: NSImage, in rect: CGRect, widthScale: CGFloat, yOffset: CGFloat = 0) {
    let markWidth = rect.width * widthScale
    let markAspectRatio = mark.size.width > 0 ? mark.size.height / mark.size.width : 1
    let markHeight = markWidth * markAspectRatio
    mark.draw(
        in: CGRect(
            x: rect.midX - markWidth / 2,
            y: rect.midY - markHeight / 2 + yOffset,
            width: markWidth,
            height: markHeight
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
}

let iconsetSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

let stalePaths = [
    optionsDir.appendingPathComponent("bridge", isDirectory: true),
    optionsDir.appendingPathComponent("pair", isDirectory: true),
    optionsDir.appendingPathComponent("waveform", isDirectory: true),
    optionsDir.appendingPathComponent("preview.png"),
    nearfieldOptionDir.appendingPathComponent("Nearfield.iconset", isDirectory: true),
    nearfieldOptionDir.appendingPathComponent("nearfield-1024.png"),
    resourcesDir.appendingPathComponent("menubar-bridge-template.png"),
    resourcesDir.appendingPathComponent("menubar-waveform-template.png"),
    resourcesDir.appendingPathComponent("menubar-pair-template.png"),
    resourcesDir.appendingPathComponent("menubar-template.png")
]
for path in stalePaths {
    try? FileManager.default.removeItem(at: path)
}

let nearfieldIconset = nearfieldOptionDir.appendingPathComponent("Nearfield.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: nearfieldIconset, withIntermediateDirectories: true)
for (filename, size) in iconsetSizes {
    try writePNG(drawNearfieldAppIcon(size: size), to: nearfieldIconset.appendingPathComponent(filename))
}
try makeICNS(from: nearfieldIconset, output: nearfieldOptionDir.appendingPathComponent("Nearfield.icns"))
try? FileManager.default.removeItem(at: nearfieldIconset)

try? FileManager.default.removeItem(at: resourcesDir.appendingPathComponent("menubar.svg"))
try FileManager.default.copyItem(at: menuBarSVG, to: resourcesDir.appendingPathComponent("menubar.svg"))

let driverIconset = driverResourcesDir.appendingPathComponent("DeviceIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: driverIconset)
try FileManager.default.createDirectory(at: driverIconset, withIntermediateDirectories: true)
for (filename, size) in iconsetSizes {
    try writePNG(drawNearfieldDeviceIcon(size: size), to: driverIconset.appendingPathComponent(filename))
}
try makeICNS(from: driverIconset, output: driverResourcesDir.appendingPathComponent("DeviceIcon.icns"))
try? FileManager.default.removeItem(at: driverIconset)
