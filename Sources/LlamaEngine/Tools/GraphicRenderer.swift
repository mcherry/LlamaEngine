import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

extension GraphicColor {
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

/// Rasterizes a `GraphicSpec` to PNG data entirely in-process via Core Graphics + Core Text
/// (both cross-platform: iOS and macOS). No WebKit, no SVG parser, no third-party deps — the
/// input is a typed shape list, so there is no markup to sanitize. The model coordinate space
/// is top-left origin, y-down (SVG-like); this converts to Core Graphics' bottom-left, y-up.
public enum GraphicRenderer {
    public enum RenderError: LocalizedError {
        case contextFailed
        case encodeFailed
        public var errorDescription: String? {
            switch self {
            case .contextFailed: return "Could not create the drawing surface."
            case .encodeFailed: return "Could not encode the image."
            }
        }
    }

    public static func render(_ spec: GraphicSpec) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: spec.width, height: spec.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.contextFailed
        }
        if let background = spec.background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))
        }
        for element in spec.elements {
            draw(element, in: context, height: spec.height)
        }
        guard let image = context.makeImage() else { throw RenderError.contextFailed }
        return try encodePNG(image)
    }

    /// Model y-down to Core Graphics y-up.
    private static func flip(_ y: Double, _ height: Int) -> CGFloat { CGFloat(Double(height) - y) }

    private static func draw(_ element: GraphicElement, in context: CGContext, height: Int) {
        switch element {
        case let .rect(x, y, width, heightValue, corner, fill, stroke, strokeWidth):
            let rect = CGRect(x: x, y: Double(height) - y - heightValue, width: width, height: heightValue)
            let path: CGPath = corner > 0
                ? CGPath(roundedRect: rect,
                         cornerWidth: CGFloat(min(corner, width / 2)),
                         cornerHeight: CGFloat(min(corner, heightValue / 2)), transform: nil)
                : CGPath(rect: rect, transform: nil)
            fillStroke(path, fill: fill, stroke: stroke, strokeWidth: strokeWidth, in: context)
        case let .circle(cx, cy, r, fill, stroke, strokeWidth):
            let rect = CGRect(x: cx - r, y: (Double(height) - cy) - r, width: 2 * r, height: 2 * r)
            fillStroke(CGPath(ellipseIn: rect, transform: nil), fill: fill, stroke: stroke, strokeWidth: strokeWidth, in: context)
        case let .ellipse(cx, cy, rx, ry, fill, stroke, strokeWidth):
            let rect = CGRect(x: cx - rx, y: (Double(height) - cy) - ry, width: 2 * rx, height: 2 * ry)
            fillStroke(CGPath(ellipseIn: rect, transform: nil), fill: fill, stroke: stroke, strokeWidth: strokeWidth, in: context)
        case let .line(x1, y1, x2, y2, stroke, strokeWidth):
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x1, y: flip(y1, height)))
            path.addLine(to: CGPoint(x: x2, y: flip(y2, height)))
            fillStroke(path, fill: nil, stroke: stroke, strokeWidth: strokeWidth, in: context)
        case let .polyline(points, fill, stroke, strokeWidth, closed):
            guard let first = points.first else { break }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: first.x, y: flip(first.y, height)))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: flip(point.y, height))) }
            if closed { path.closeSubpath() }
            fillStroke(path, fill: fill, stroke: stroke, strokeWidth: strokeWidth, in: context)
        case let .text(x, y, string, fontSize, fill, bold, anchor):
            drawText(string, x: x, baselineY: flip(y, height), fontSize: fontSize,
                     color: fill, bold: bold, anchor: anchor, in: context)
        }
    }

    private static func fillStroke(_ path: CGPath, fill: GraphicColor?, stroke: GraphicColor?,
                                   strokeWidth: Double, in context: CGContext) {
        let hasStroke = stroke != nil && strokeWidth > 0
        guard fill != nil || hasStroke else { return }
        context.addPath(path)
        if let fill { context.setFillColor(fill.cgColor) }
        if let stroke, hasStroke {
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(CGFloat(strokeWidth))
            context.setLineJoin(.round)
            context.setLineCap(.round)
        }
        switch (fill != nil, hasStroke) {
        case (true, true): context.drawPath(using: .fillStroke)
        case (true, false): context.drawPath(using: .fill)
        default: context.drawPath(using: .stroke)
        }
    }

    private static func drawText(_ string: String, x: Double, baselineY: CGFloat, fontSize: Double,
                                 color: GraphicColor, bold: Bool, anchor: TextAnchor, in context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, CGFloat(fontSize), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(fontSize), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let width = CTLineGetBoundsWithOptions(line, .useOpticalBounds).width
        let startX: CGFloat
        switch anchor {
        case .start: startX = CGFloat(x)
        case .middle: startX = CGFloat(x) - width / 2
        case .end: startX = CGFloat(x) - width
        }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: startX, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed }
        return data as Data
    }
}
