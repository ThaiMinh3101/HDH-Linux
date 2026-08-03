// RPGPlayer/EngineRGSS/WindowRenderer.swift
//
// M6.4 — Render RGSS3 Window (windowskin 9-slice + text) qua Metal.
//
// CLEAN-ROOM: viết từ RGSS3 Reference Manual (help file công khai đi kèm
// RPG Maker VX Ace). KHÔNG tham chiếu cấu trúc field/logic từ bất kỳ engine
// mã nguồn mở GPL/LGPL nào (mkxp-z, v.v.).

import Foundation
import Metal
import MetalKit
import UIKit

/// Khung chứa thông tin render của 1 Window (đã copy từ C callback).
struct RGSSWindowRenderState {
    var x: Int = 0
    var y: Int = 0
    var width: Int = 0
    var height: Int = 0
    var opacity: Int = 255
    var visible: Bool = true
    var text: String = ""
}

/// Renderer vẽ Window RGSS3 (windowskin 9-slice + text) thành MTLTexture.
final class WindowRenderer {
    static let windowskinSize: Int = 128
    static let cornerSize: Int = 16
    static let fillSize: Int = 96
    static let contentPadding: Int = 16
    static let fontSize: CGFloat = 18

    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private(set) var windowTexture: MTLTexture?

    init?(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    @discardableResult
    func render(state: RGSSWindowRenderState, gameRoot: URL) -> Bool {
        guard state.visible, state.width > 0, state.height > 0 else {
            windowTexture = nil
            return true
        }
        guard let context = makeContext(width: state.width, height: state.height) else {
            print("[WindowRenderer] ❌ Không tạo được bitmap context")
            return false
        }
        drawNineSlice(in: context, windowskin: loadWindowskin(from: gameRoot))
        if !state.text.isEmpty {
            drawText(state.text, in: context, windowState: state)
        }
        guard let cgImage = context.makeImage() else {
            print("[WindowRenderer] ❌ makeImage() thất bại")
            return false
        }
        do {
            windowTexture = try textureLoader.newTexture(
                cgImage: cgImage,
                options: [.textureUsage: MTLTextureUsage.shaderRead.rawValue,
                          .SRGB: false]
            )
            return true
        } catch {
            print("[WindowRenderer] ❌ Texture lỗi: \(error.localizedDescription)")
            return false
        }
    }

    private func loadWindowskin(from gameRoot: URL) -> UIImage? {
        let url = gameRoot.appendingPathComponent("Graphics/System/Window.png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        let cs = CGColorSpaceCreateDeviceRGB()
        return CGContext(data: nil, width: width, height: height,
                         bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: cs,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    // MARK: - 9-slice drawing

    private func drawNineSlice(in ctx: CGContext, windowskin: UIImage?) {
        guard let img = windowskin, let cg = img.cgImage else {
            drawGrayFallback(in: ctx)
            return
        }
        let c = Self.cornerSize, f = Self.fillSize
        let l = Self.nineSliceLayout(width: ctx.width, height: ctx.height)
        let srcs = [
            CGRect(x: 0, y: 0, width: c, height: c),
            CGRect(x: c, y: 0, width: f, height: c),
            CGRect(x: f + c, y: 0, width: c, height: c),
            CGRect(x: 0, y: c, width: c, height: f),
            CGRect(x: c, y: c, width: f, height: f),
            CGRect(x: f + c, y: c, width: c, height: f),
            CGRect(x: 0, y: f + c, width: c, height: c),
            CGRect(x: c, y: f + c, width: f, height: c),
            CGRect(x: f + c, y: f + c, width: c, height: c)
        ]
        let dests = [l.topLeft, l.topEdge, l.topRight, l.leftEdge, l.center,
                     l.rightEdge, l.bottomLeft, l.bottomEdge, l.bottomRight]
        for i in 0..<9 { drawRegion(source: srcs[i], dest: dests[i], cgImage: cg, in: ctx) }
    }

    private func drawRegion(source: CGRect, dest: CGRect, cgImage: CGImage, in ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: dest)
        let sx = dest.width / source.width
        let sy = dest.height / source.height
        ctx.translateBy(x: dest.origin.x, y: dest.origin.y)
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -source.origin.x, y: -source.origin.y)
        ctx.draw(cgImage, in: CGRect(origin: .zero,
                                     size: CGSize(width: cgImage.width, height: cgImage.height)))
        ctx.restoreGState()
    }

    private func drawGrayFallback(in ctx: CGContext) {
        let w = CGFloat(ctx.width), h = CGFloat(ctx.height)
        ctx.setFillColor(UIColor(white: 0.25, alpha: 0.9).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(UIColor(white: 0.6, alpha: 0.9).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 2))
        ctx.fill(CGRect(x: 0, y: h - 2, width: w, height: 2))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: h))
        ctx.fill(CGRect(x: w - 2, y: 0, width: 2, height: h))
    }

    // MARK: - Text

    private func drawText(_ text: String, in ctx: CGContext, windowState s: RGSSWindowRenderState) {
        let pad = CGFloat(Self.contentPadding)
        let rect = CGRect(x: pad, y: pad,
                          width: max(1, CGFloat(s.width) - pad * 2),
                          height: max(1, CGFloat(s.height) - pad * 2))
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: Self.fontSize),
            .foregroundColor: UIColor.white,
            .paragraphStyle: para]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    // MARK: - Testable layout math

    static func nineSliceLayout(width: Int, height: Int) -> (topLeft: CGRect, topEdge: CGRect, topRight: CGRect,
                                                             leftEdge: CGRect, center: CGRect, rightEdge: CGRect,
                                                             bottomLeft: CGRect, bottomEdge: CGRect, bottomRight: CGRect) {
        let w = CGFloat(width), h = CGFloat(height), c = CGFloat(cornerSize)
        let ew = max(0, w - c * 2), eh = max(0, h - c * 2)
        return (
            CGRect(x: 0, y: h - c, width: c, height: c),
            CGRect(x: c, y: h - c, width: ew, height: c),
            CGRect(x: w - c, y: h - c, width: c, height: c),
            CGRect(x: 0, y: c, width: c, height: eh),
            CGRect(x: c, y: c, width: ew, height: eh),
            CGRect(x: w - c, y: c, width: c, height: eh),
            CGRect(x: 0, y: 0, width: c, height: c),
            CGRect(x: c, y: 0, width: ew, height: c),
            CGRect(x: w - c, y: 0, width: c, height: c)
        )
    }

    static func isValidWindowSize(width: Int, height: Int) -> Bool {
        width >= cornerSize * 2 && height >= cornerSize * 2
    }
}
