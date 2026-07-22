import XCTest
import CoreGraphics
import ImageIO
@testable import LlamaEngine

final class RenderGraphicTests: XCTestCase {

    // MARK: - Color parsing

    func testColorParse() {
        XCTAssertEqual(GraphicColor.parse("#ff0000"), GraphicColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(GraphicColor.parse("#f00"), GraphicColor(red: 1, green: 0, blue: 0))   // shorthand
        XCTAssertEqual(GraphicColor.parse("RED"), GraphicColor(red: 1, green: 0, blue: 0))    // named, case-insensitive
        let semi = GraphicColor.parse("#00ff0080")
        XCTAssertEqual(semi?.green, 1)
        XCTAssertEqual(semi?.alpha ?? 0, 0.5, accuracy: 0.02)
        XCTAssertNil(GraphicColor.parse("none"))
        XCTAssertNil(GraphicColor.parse("transparent"))
        XCTAssertNil(GraphicColor.parse(""))
        XCTAssertNil(GraphicColor.parse("bogus"))
    }

    // MARK: - Spec parsing

    func testSpecParseValid() throws {
        let args = JSONValue.object([
            "width": .number(200), "height": .number(120), "background": .string("#ffffff"),
            "elements": .array([
                .object(["type": .string("circle"), "cx": .number(100), "cy": .number(60), "r": .number(40), "fill": .string("#4287f5")]),
                .object(["type": .string("line"), "x1": .number(0), "y1": .number(0), "x2": .number(200), "y2": .number(120)]),
                .object(["type": .string("polygon"),
                         "points": .array([.array([.number(10), .number(10)]),
                                           .array([.number(50), .number(10)]),
                                           .array([.number(30), .number(40)])]),
                         "fill": .string("green")]),
                .object(["type": .string("text"), "x": .number(100), "y": .number(110), "text": .string("Hi"), "anchor": .string("middle")])
            ])
        ])
        let spec = try GraphicSpec.parse(args)
        XCTAssertEqual(spec.width, 200)
        XCTAssertEqual(spec.height, 120)
        XCTAssertEqual(spec.background, GraphicColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(spec.elements.count, 4)
    }

    func testShapeWithNoColorsDefaultsToBlackFill() throws {
        let spec = try GraphicSpec.parse(.object([
            "width": .number(10), "height": .number(10),
            "elements": .array([.object(["type": .string("rect"), "x": .number(1), "y": .number(1), "width": .number(4), "height": .number(4)])])
        ]))
        guard case let .rect(_, _, _, _, _, fill, stroke, _) = spec.elements[0] else { return XCTFail("expected rect") }
        XCTAssertEqual(fill, GraphicColor.black)
        XCTAssertNil(stroke)
    }

    func testSpecParseRejections() {
        // missing width
        XCTAssertThrowsError(try GraphicSpec.parse(.object(["height": .number(10),
            "elements": .array([.object(["type": .string("rect"), "x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1)])])])))
        // dimension out of range
        XCTAssertThrowsError(try GraphicSpec.parse(.object(["width": .number(9999), "height": .number(10),
            "elements": .array([.object(["type": .string("rect"), "x": .number(0), "y": .number(0), "width": .number(1), "height": .number(1)])])])))
        // empty elements
        XCTAssertThrowsError(try GraphicSpec.parse(.object(["width": .number(10), "height": .number(10), "elements": .array([])])))
        // unknown element type
        XCTAssertThrowsError(try GraphicSpec.parse(.object(["width": .number(10), "height": .number(10),
            "elements": .array([.object(["type": .string("blob")])])])))
        // rect missing required fields
        XCTAssertThrowsError(try GraphicSpec.parse(.object(["width": .number(10), "height": .number(10),
            "elements": .array([.object(["type": .string("rect")])])])))
        // malformed point
        XCTAssertThrowsError(try GraphicSpec.parse(.object(["width": .number(10), "height": .number(10),
            "elements": .array([.object(["type": .string("polyline"), "points": .array([.array([.number(1)])])])])])))
    }

    func testElementCap() {
        let many = (0..<(GraphicSpec.maxElements + 1)).map { _ in
            JSONValue.object(["type": .string("circle"), "cx": .number(1), "cy": .number(1), "r": .number(1)])
        }
        XCTAssertThrowsError(try GraphicSpec.parse(.object(["width": .number(10), "height": .number(10), "elements": .array(many)])))
    }

    // MARK: - Rendering

    func testRenderProducesPNGWithCorrectDimensions() throws {
        let spec = GraphicSpec(width: 120, height: 80,
                               background: GraphicColor(red: 1, green: 1, blue: 1),
                               elements: [
                                .rect(x: 10, y: 10, width: 100, height: 60, cornerRadius: 8,
                                      fill: GraphicColor(red: 0.2, green: 0.5, blue: 0.9), stroke: .black, strokeWidth: 2),
                                .circle(cx: 60, cy: 40, r: 20, fill: nil, stroke: .black, strokeWidth: 1),
                                .text(x: 60, y: 74, string: "Hi", fontSize: 14, fill: .black, bold: true, anchor: .middle)
                               ])
        let data = try GraphicRenderer.render(spec)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])   // PNG magic
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
    }

    func testRenderGraphicToolReturnsImage() async throws {
        let args = JSONValue.object([
            "width": .number(100), "height": .number(60),
            "elements": .array([
                .object(["type": .string("rect"), "x": .number(10), "y": .number(10),
                         "width": .number(80), "height": .number(40), "fill": .string("#00ff00")])
            ])
        ])
        let result = try await RenderGraphicTool().execute(args)
        XCTAssertFalse(result.isError)
        let png = try XCTUnwrap(result.imageData)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(result.content.contains("100×60"))
    }

    func testRenderGraphicToolValidatesArguments() {
        XCTAssertThrowsError(try RenderGraphicTool().validate(.object(["width": .number(10)])))   // no elements
    }
}
