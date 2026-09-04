#!/usr/bin/env swift
//
// 双摄相机 App Icon 生成器
//
//   swift DesignAssets/make-app-icon.swift
//
// 图形语义：一大一小两个画框，正是本应用的成片形态——后摄铺满画面，
// 前摄以画中画嵌在右下角。相比通用的「相机镜头」图形，它在 40×40 下
// 依然只有两个清晰色块，不会糊成一团，且与应用的实际输出直接对应。
//
// 输出 1024 三份：常规、深色、单色。后两者背景透明，由系统合成。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Variant {
    case standard
    case dark
    case tinted
}

let size: CGFloat = 1024

func makeContext() -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("无法创建绘图上下文")
    }
    return context
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, a]
    )!
}

/// 圆角矩形路径。
func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawBackground(_ context: CGContext, variant: Variant) {
    guard variant == .standard else { return }
    // 浅天蓝到品牌蓝的对角渐变，配白色图形。
    // 白色图形使深色与单色变体可直接复用同一套前景色，无需按底色另行调整。
    let colors = [rgb(140, 193, 255), rgb(62, 120, 232)] as CFArray
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colors,
        locations: [0, 1]
    ) else { return }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )
}

func foregroundColor(_ variant: Variant) -> CGColor {
    switch variant {
    case .standard, .dark: return rgb(255, 255, 255)
    case .tinted: return rgb(255, 255, 255)
    }
}

/// 在指定路径上开孔。标准变体把背景补回孔内，深色与单色变体保持透明由系统合成。
func knockOut(_ context: CGContext, path: CGPath, variant: Variant) {
    context.setBlendMode(.clear)
    context.addPath(path)
    context.fillPath()
    context.setBlendMode(.normal)

    guard variant == .standard else { return }
    context.saveGState()
    context.addPath(path)
    context.clip()
    drawBackground(context, variant: .standard)
    context.restoreGState()
}

func draw(variant: Variant) -> CGImage {
    let context = makeContext()
    drawBackground(context, variant: variant)

    let white = foregroundColor(variant)

    // 光圈环：主体元素，先把「相机」立住。粗描边保证 40×40 下不糊。
    let ringCenter = CGPoint(x: 462, y: 566)
    let ringRadius: CGFloat = 236
    context.setStrokeColor(white)
    context.setLineWidth(84)
    context.addEllipse(in: CGRect(
        x: ringCenter.x - ringRadius,
        y: ringCenter.y - ringRadius,
        width: ringRadius * 2,
        height: ringRadius * 2
    ))
    context.strokePath()

    // 光圈内芯。
    let irisRadius: CGFloat = 62
    context.setFillColor(white)
    context.addEllipse(in: CGRect(
        x: ringCenter.x - irisRadius,
        y: ringCenter.y - irisRadius,
        width: irisRadius * 2,
        height: irisRadius * 2
    ))
    context.fillPath()

    // 前摄画中画角标：3:4 竖幅，压在光圈右下方，对应应用默认的画中画位置。
    let pipWidth: CGFloat = 208
    let pipHeight = pipWidth * 4 / 3
    let pipRect = CGRect(x: 566, y: 196, width: pipWidth, height: pipHeight)

    // 先在角标周围开一圈槽，让光圈从它背后穿过时留出干净间隙。
    // 没有这道间隙，两个白色形状会在小尺寸下粘连成一团。
    knockOut(context, path: roundedRect(pipRect.insetBy(dx: -26, dy: -26), radius: 78), variant: variant)

    context.setFillColor(white)
    context.addPath(roundedRect(pipRect, radius: 54))
    context.fillPath()

    // 角标中的前摄镜头：与主光圈同一套「环 + 芯」语汇的缩小版。
    knockOut(
        context,
        path: CGPath(
            ellipseIn: CGRect(x: pipRect.midX - 46, y: pipRect.midY - 46, width: 92, height: 92),
            transform: nil
        ),
        variant: variant
    )

    guard let image = context.makeImage() else { fatalError("渲染失败") }
    return image
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("无法写入 \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("无法完成 \(path)") }
    print("已生成 \(path)")
}

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

write(draw(variant: .standard), to: "\(outputDirectory)/Icon-1024.png")
write(draw(variant: .dark), to: "\(outputDirectory)/Icon-1024-Dark.png")
write(draw(variant: .tinted), to: "\(outputDirectory)/Icon-1024-Tinted.png")
