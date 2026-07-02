import XCTest
@testable import LlamaEngine

final class ModelManagementTests: XCTestCase {

    // MARK: - PullProgress

    func testPullFractionComputed() {
        let p = PullProgress(status: "downloading", completed: 50, total: 200)
        XCTAssertEqual(p.fraction ?? -1, 0.25, accuracy: 1e-6)
    }

    func testPullFractionNilWhenNoTotal() {
        XCTAssertNil(PullProgress(status: "pulling manifest", completed: nil, total: nil).fraction)
        XCTAssertNil(PullProgress(status: "x", completed: 10, total: 0).fraction)
    }

    // MARK: - RunningModel / OllamaModel size labels

    func testRunningModelVramLabel() {
        XCTAssertNotNil(RunningModel(name: "m", sizeVRAM: 1_000_000_000).vramLabel)
        XCTAssertNil(RunningModel(name: "m", sizeVRAM: nil).vramLabel)
    }

    func testOllamaModelSizeLabel() {
        XCTAssertNotNil(OllamaModel(name: "m", details: nil, size: 18_000_000_000).sizeLabel)
        XCTAssertNil(OllamaModel(name: "m", details: nil, size: nil).sizeLabel)
    }

    // MARK: - Decoding

    func testTagsDecodeWithSize() throws {
        let json = #"{"models":[{"name":"qwen-14b","size":18556700707,"details":{"family":"qwen"}}]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let response = try JSONDecoder().decode(TagsResponse.self, from: data)
        XCTAssertEqual(response.models.first?.size, 18556700707)
        XCTAssertEqual(response.models.first?.name, "qwen-14b")
    }

    func testPsDecodeSnakeCase() throws {
        let json = #"{"models":[{"name":"deepseek-r1:32b","size_vram":24726523083}]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(PsResponse.self, from: data)
        XCTAssertEqual(response.models.first?.name, "deepseek-r1:32b")
        XCTAssertEqual(response.models.first?.sizeVram, 24726523083)
    }
}
