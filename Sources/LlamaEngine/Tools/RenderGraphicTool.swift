import Foundation

/// A color for the drawing DSL, components in 0...1. Parsed from a hex string ("#rrggbb",
/// "#rgb", "#rrggbbaa") or a small set of names; "none"/"transparent"/empty parse to nil.
public struct GraphicColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = GraphicColor(red: 0, green: 0, blue: 0)

    static let named: [String: GraphicColor] = [
        "black": GraphicColor(red: 0, green: 0, blue: 0),
        "white": GraphicColor(red: 1, green: 1, blue: 1),
        "red": GraphicColor(red: 1, green: 0, blue: 0),
        "green": GraphicColor(red: 0, green: 0.5, blue: 0),
        "lime": GraphicColor(red: 0, green: 1, blue: 0),
        "blue": GraphicColor(red: 0, green: 0, blue: 1),
        "yellow": GraphicColor(red: 1, green: 1, blue: 0),
        "orange": GraphicColor(red: 1, green: 0.65, blue: 0),
        "purple": GraphicColor(red: 0.5, green: 0, blue: 0.5),
        "cyan": GraphicColor(red: 0, green: 1, blue: 1),
        "magenta": GraphicColor(red: 1, green: 0, blue: 1),
        "pink": GraphicColor(red: 1, green: 0.75, blue: 0.8),
        "brown": GraphicColor(red: 0.65, green: 0.16, blue: 0.16),
        "navy": GraphicColor(red: 0, green: 0, blue: 0.5),
        "teal": GraphicColor(red: 0, green: 0.5, blue: 0.5),
        "gray": GraphicColor(red: 0.5, green: 0.5, blue: 0.5),
        "grey": GraphicColor(red: 0.5, green: 0.5, blue: 0.5),
        "lightgray": GraphicColor(red: 0.83, green: 0.83, blue: 0.83),
        "darkgray": GraphicColor(red: 0.66, green: 0.66, blue: 0.66)
    ]

    /// Parses a color, or nil for missing/none/transparent (treated as "no color").
    static func parse(_ raw: String) -> GraphicColor? {
        let string = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if string.isEmpty || string == "none" || string == "transparent" { return nil }
        if let named = named[string] { return named }
        guard string.hasPrefix("#") else { return nil }
        var hex = String(string.dropFirst())
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        let components: [Double] = stride(from: 0, to: hex.count, by: 2).compactMap { start in
            let lower = hex.index(hex.startIndex, offsetBy: start)
            let upper = hex.index(lower, offsetBy: 2)
            return UInt8(hex[lower..<upper], radix: 16).map { Double($0) / 255.0 }
        }
        guard components.count == hex.count / 2 else { return nil }
        return GraphicColor(red: components[0], green: components[1], blue: components[2],
                            alpha: components.count == 4 ? components[3] : 1)
    }
}

public struct GraphicPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum TextAnchor: String, Sendable, Equatable {
    case start, middle, end
}

/// One shape in the drawing DSL. Coordinates are pixels, origin top-left, y down (SVG-like).
public enum GraphicElement: Sendable, Equatable {
    case rect(x: Double, y: Double, width: Double, height: Double, cornerRadius: Double,
              fill: GraphicColor?, stroke: GraphicColor?, strokeWidth: Double)
    case circle(cx: Double, cy: Double, r: Double, fill: GraphicColor?, stroke: GraphicColor?, strokeWidth: Double)
    case ellipse(cx: Double, cy: Double, rx: Double, ry: Double, fill: GraphicColor?, stroke: GraphicColor?, strokeWidth: Double)
    case line(x1: Double, y1: Double, x2: Double, y2: Double, stroke: GraphicColor, strokeWidth: Double)
    case polyline(points: [GraphicPoint], fill: GraphicColor?, stroke: GraphicColor?, strokeWidth: Double, closed: Bool)
    case text(x: Double, y: Double, string: String, fontSize: Double, fill: GraphicColor, bold: Bool, anchor: TextAnchor)
}

/// A validated canvas + shape list, parsed from tool arguments. All parsing is pure and
/// bounded (dimension + element caps), so it unit-tests without any drawing.
public struct GraphicSpec: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var background: GraphicColor?
    public var elements: [GraphicElement]

    public init(width: Int, height: Int, background: GraphicColor?, elements: [GraphicElement]) {
        self.width = width
        self.height = height
        self.background = background
        self.elements = elements
    }

    public static let maxDimension = 2048
    public static let maxElements = 500

    public static func parse(_ arguments: JSONValue) throws -> GraphicSpec {
        guard let width = intField(arguments, "width"), let height = intField(arguments, "height") else {
            throw ToolError.invalidArgument("Provide integer width and height.")
        }
        guard (1...maxDimension).contains(width), (1...maxDimension).contains(height) else {
            throw ToolError.invalidArgument("width and height must be between 1 and \(maxDimension).")
        }
        guard let rawElements = arguments.array("elements"), !rawElements.isEmpty else {
            throw ToolError.invalidArgument("Provide a non-empty elements array.")
        }
        guard rawElements.count <= maxElements else {
            throw ToolError.invalidArgument("Too many elements (max \(maxElements)).")
        }
        let elements = try rawElements.enumerated().map { try parseElement($1, index: $0) }
        return GraphicSpec(width: width, height: height,
                           background: color(arguments, "background"), elements: elements)
    }

    static func intField(_ value: JSONValue, _ key: String) -> Int? {
        value.int(key) ?? value.double(key).map { Int($0) }
    }

    static func color(_ value: JSONValue, _ key: String) -> GraphicColor? {
        value.string(key).flatMap(GraphicColor.parse)
    }

    static func parseElement(_ value: JSONValue, index: Int) throws -> GraphicElement {
        guard let type = value.string("type") else {
            throw ToolError.invalidArgument("Element \(index) is missing a \"type\".")
        }
        func num(_ key: String) throws -> Double {
            guard let value = value.double(key) else {
                throw ToolError.invalidArgument("Element \(index) (\(type)) is missing \"\(key)\".")
            }
            return value
        }
        let fill = color(value, "fill")
        let stroke = color(value, "stroke")
        let strokeWidth = value.double("stroke_width") ?? 1

        switch type {
        case "rect":
            let (f, s) = fillDefault(fill, stroke)
            return .rect(x: try num("x"), y: try num("y"), width: try num("width"), height: try num("height"),
                         cornerRadius: max(0, value.double("corner_radius") ?? 0),
                         fill: f, stroke: s, strokeWidth: strokeWidth)
        case "circle":
            let (f, s) = fillDefault(fill, stroke)
            return .circle(cx: try num("cx"), cy: try num("cy"), r: try num("r"),
                           fill: f, stroke: s, strokeWidth: strokeWidth)
        case "ellipse":
            let (f, s) = fillDefault(fill, stroke)
            return .ellipse(cx: try num("cx"), cy: try num("cy"), rx: try num("rx"), ry: try num("ry"),
                            fill: f, stroke: s, strokeWidth: strokeWidth)
        case "line":
            return .line(x1: try num("x1"), y1: try num("y1"), x2: try num("x2"), y2: try num("y2"),
                         stroke: stroke ?? .black, strokeWidth: max(0.5, strokeWidth))
        case "polyline", "polygon":
            let closed = type == "polygon"
            let points = try parsePoints(value.array("points"), index: index)
            let effectiveStroke = (closed && fill != nil) ? stroke : (stroke ?? .black)
            return .polyline(points: points, fill: closed ? fill : nil,
                             stroke: effectiveStroke, strokeWidth: max(0.5, strokeWidth), closed: closed)
        case "text":
            guard let string = value.string("text"), !string.isEmpty else {
                throw ToolError.invalidArgument("Text element \(index) is missing \"text\".")
            }
            let anchor = value.string("anchor").flatMap(TextAnchor.init) ?? .start
            return .text(x: try num("x"), y: try num("y"), string: String(string.prefix(500)),
                         fontSize: max(1, value.double("font_size") ?? 16),
                         fill: fill ?? .black, bold: value.string("weight") == "bold", anchor: anchor)
        default:
            throw ToolError.invalidArgument("Element \(index) has unknown type \"\(type)\".")
        }
    }

    /// A shape with neither fill nor stroke would be invisible; default it to a black fill.
    private static func fillDefault(_ fill: GraphicColor?, _ stroke: GraphicColor?) -> (GraphicColor?, GraphicColor?) {
        (fill == nil && stroke == nil) ? (.black, nil) : (fill, stroke)
    }

    static func parsePoints(_ array: [JSONValue]?, index: Int) throws -> [GraphicPoint] {
        guard let array, array.count >= 2 else {
            throw ToolError.invalidArgument("Element \(index) needs a \"points\" array of at least 2 points.")
        }
        return try array.map { point in
            guard let pair = point.arrayValue, pair.count >= 2,
                  let x = pair[0].doubleValue, let y = pair[1].doubleValue else {
                throw ToolError.invalidArgument("Element \(index) has a malformed point (expected [x, y]).")
            }
            return GraphicPoint(x: x, y: y)
        }
    }
}

/// Draws a vector graphic and returns it as a PNG for the user to see. `pure` — deterministic,
/// no I/O, no side effects — so it auto-runs. The model emits a typed shape list (not markup),
/// which the engine rasterizes in-process with Core Graphics; there is nothing to sanitize and
/// it renders identically on macOS and iOS.
public struct RenderGraphicTool: AgentTool {
    public init() {}

    public let name = "render_graphic"
    public let description = """
    Draws a vector graphic shown to the user. Give a canvas size and a list of shape \
    elements; the app rasterizes it locally. Coordinates are pixels with the origin at the \
    TOP-LEFT (x right, y down). Colors are hex ("#rrggbb" or "#rgb") or names like "red"; omit \
    fill or stroke to leave it off. Element types and fields:
    - rect: x, y, width, height, optional corner_radius, fill, stroke, stroke_width
    - circle: cx, cy, r, fill, stroke, stroke_width
    - ellipse: cx, cy, rx, ry, fill, stroke, stroke_width
    - line: x1, y1, x2, y2, stroke, stroke_width
    - polyline / polygon: points (array of [x, y] pairs), fill, stroke, stroke_width
    - text: x, y, text, optional font_size, fill, weight ("bold"), anchor ("start"/"middle"/"end")
    Example: {"width":200,"height":120,"background":"#ffffff","elements":[{"type":"circle","cx":100,"cy":60,"r":40,"fill":"#4287f5"},{"type":"text","x":100,"y":112,"text":"Hi","anchor":"middle"}]}
    """
    public let riskTier: ToolRiskTier = .pure

    public var parameters: JSONSchema {
        .object(properties: [
            "width": .object([
                "type": .string("integer"),
                "description": .string("Canvas width in pixels (1-2048).")
            ]),
            "height": .object([
                "type": .string("integer"),
                "description": .string("Canvas height in pixels (1-2048).")
            ]),
            "background": .object([
                "type": .string("string"),
                "description": .string("Optional background color; omit for transparent.")
            ]),
            "elements": .object([
                "type": .string("array"),
                "description": .string("Shapes to draw, back-to-front. See the tool description for each element's fields.")
            ])
        ], required: ["width", "height", "elements"])
    }

    public func validate(_ arguments: JSONValue) throws {
        _ = try GraphicSpec.parse(arguments)
    }

    public func execute(_ arguments: JSONValue) async throws -> ToolResult {
        let spec = try GraphicSpec.parse(arguments)
        let png = try GraphicRenderer.render(spec)
        let summary = "Rendered a \(spec.width)×\(spec.height) graphic with \(spec.elements.count) element\(spec.elements.count == 1 ? "" : "s")."
        return ToolResult(content: summary, displaySummary: summary, imageData: png)
    }
}
