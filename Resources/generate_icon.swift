#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ClipNote アプリアイコン / メニューバーアイコンを生成する。
/// 実行: swift Resources/generate_icon.swift

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .standardizedFileURL.deletingLastPathComponent()
let outDir = root

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "PNG 書き込み失敗: \(url.path)")
}

func makeContext(size: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawAppIcon(size: Int) -> CGImage {
    let ctx = makeContext(size: size)
    let S = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()

    // macOS スクワークル相当。キャンバスいっぱいに描き、四隅は透明。
    let iconRect = CGRect(x: 0, y: 0, width: S, height: S)
    let corner = S * 0.223
    ctx.addPath(roundedRect(iconRect, radius: corner))
    ctx.clip()

    let top = CGColor(srgbRed: 1.00, green: 0.80, blue: 0.22, alpha: 1)
    let bot = CGColor(srgbRed: 0.93, green: 0.66, blue: 0.08, alpha: 1)
    let grad = CGGradient(colorsSpace: cs, colors: [top, bot] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: S / 2, y: S), end: CGPoint(x: S / 2, y: 0), options: [])

    // 紙
    let paperW = S * 0.50
    let paperH = S * 0.52
    let paper = CGRect(x: (S - paperW) / 2, y: (S - paperH) / 2 - S * 0.01,
                       width: paperW, height: paperH)
    let paperR = paperW * 0.13

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.028,
                  color: CGColor(srgbRed: 0.45, green: 0.30, blue: 0.02, alpha: 0.28))
    ctx.setFillColor(CGColor(srgbRed: 0.996, green: 0.980, blue: 0.950, alpha: 1))
    ctx.addPath(roundedRect(paper, radius: paperR))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.setFillColor(CGColor(srgbRed: 0.996, green: 0.980, blue: 0.950, alpha: 1))
    ctx.addPath(roundedRect(paper, radius: paperR))
    ctx.fillPath()

    // テキスト線（長い→短い）
    let lineColor = CGColor(srgbRed: 0.94, green: 0.70, blue: 0.14, alpha: 1)
    ctx.setFillColor(lineColor)
    let lineH = paperH * 0.055
    let lineX = paper.minX + paperW * 0.16
    let fracs: [CGFloat] = [0.68, 0.54, 0.38]
    var lineY = paper.midY + paperH * 0.10
    for f in fracs {
        let r = CGRect(x: lineX, y: lineY, width: paperW * f, height: lineH)
        ctx.addPath(roundedRect(r, radius: lineH / 2))
        ctx.fillPath()
        lineY -= paperH * 0.155
    }

    drawPaperclip(
        ctx: ctx,
        anchor: CGPoint(x: paper.maxX - paperW * 0.04, y: paper.maxY - paperH * 0.08),
        length: S * 0.155
    )

    return ctx.makeImage()!
}

/// ゼムクリップ。SF Symbol をライトグレーで焼き込む。
func drawPaperclip(ctx: CGContext, anchor: CGPoint, length: CGFloat) {
    let config = NSImage.SymbolConfiguration(pointSize: length * 1.25, weight: .bold)
    guard let symbol = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }

    let scale: CGFloat = 4
    let pt = symbol.size
    guard pt.width > 0, pt.height > 0 else { return }
    let pxW = max(1, Int(pt.width * scale))
    let pxH = max(1, Int(pt.height * scale))
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return }
    rep.size = pt
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(srgbRed: 0.91, green: 0.92, blue: 0.94, alpha: 1).setFill()
    NSRect(origin: .zero, size: pt).fill()
    symbol.draw(in: NSRect(origin: .zero, size: pt), from: .zero, operation: .destinationIn, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let cg = rep.cgImage else { return }

    ctx.saveGState()
    ctx.translateBy(x: anchor.x, y: anchor.y)
    ctx.rotate(by: 0.40)
    let dest = CGRect(x: -pt.width * 0.45, y: -pt.height * 0.35, width: pt.width, height: pt.height)
    ctx.draw(cg, in: dest)
    ctx.restoreGState()
}

func drawMenuBarIcon(size: Int) -> CGImage {
    let ctx = makeContext(size: size)
    let S = CGFloat(size)
    ctx.setStrokeColor(CGColor.black)
    ctx.setFillColor(CGColor.black)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let note = CGRect(x: S * 0.18, y: S * 0.12, width: S * 0.54, height: S * 0.62)
    ctx.setLineWidth(S * 0.08)
    ctx.addPath(roundedRect(note, radius: S * 0.09))
    ctx.strokePath()

    ctx.setLineWidth(S * 0.07)
    let x0 = note.minX + S * 0.10
    var y = note.maxY - S * 0.20
    for f in [CGFloat(0.62), 0.46] {
        ctx.move(to: CGPoint(x: x0, y: y))
        ctx.addLine(to: CGPoint(x: x0 + note.width * f, y: y))
        ctx.strokePath()
        y -= S * 0.16
    }

    let config = NSImage.SymbolConfiguration(pointSize: S * 0.42, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let pt = symbol.size
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: max(1, Int(pt.width * 4)), pixelsHigh: max(1, Int(pt.height * 4)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) {
            rep.size = pt
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.black.setFill()
            NSRect(origin: .zero, size: pt).fill()
            symbol.draw(in: NSRect(origin: .zero, size: pt), from: .zero, operation: .destinationIn, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            if let cg = rep.cgImage {
                ctx.saveGState()
                ctx.translateBy(x: note.maxX - S * 0.02, y: note.maxY - S * 0.04)
                ctx.rotate(by: 0.45)
                ctx.draw(cg, in: CGRect(x: -pt.width * 0.3, y: -pt.height * 0.15, width: pt.width, height: pt.height))
                ctx.restoreGState()
            }
        }
    }

    return ctx.makeImage()!
}

let appPNG = outDir.appendingPathComponent("AppIcon-1024.png")
let menuPNG = outDir.appendingPathComponent("MenuBarIcon.png")
writePNG(drawAppIcon(size: 1024), to: appPNG)
writePNG(drawMenuBarIcon(size: 36), to: menuPNG)
print("wrote \(appPNG.path)")
print("wrote \(menuPNG.path)")

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func sips(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "sips \(args) failed")
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    sips(["-z", "\(px)", "\(px)", appPNG.path, "--out", iconset.appendingPathComponent(name).path])
}

let icns = outDir.appendingPathComponent("AppIcon.icns")
let util = Process()
util.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
util.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! util.run()
util.waitUntilExit()
precondition(util.terminationStatus == 0, "iconutil failed")
try? FileManager.default.removeItem(at: iconset)
print("wrote \(icns.path)")
