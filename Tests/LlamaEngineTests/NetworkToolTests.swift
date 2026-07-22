import XCTest
import NaturalLanguage
@testable import LlamaEngine

final class NetworkToolTests: XCTestCase {

    // MARK: - get_weather

    func testGeocodeURLIncludesCityAndCount() {
        let url = GetWeatherTool.geocodeURL(city: "Paris").absoluteString
        XCTAssertTrue(url.hasPrefix("https://geocoding-api.open-meteo.com/v1/search"))
        XCTAssertTrue(url.contains("name=Paris"))
        XCTAssertTrue(url.contains("count=1"))
    }

    func testForecastURLReflectsUnits() {
        let metric = GetWeatherTool.forecastURL(latitude: 48.85, longitude: 2.35, units: .metric).absoluteString
        XCTAssertTrue(metric.contains("temperature_unit=celsius"))
        XCTAssertTrue(metric.contains("wind_speed_unit=kmh"))
        let imperial = GetWeatherTool.forecastURL(latitude: 48.85, longitude: 2.35, units: .imperial).absoluteString
        XCTAssertTrue(imperial.contains("temperature_unit=fahrenheit"))
        XCTAssertTrue(imperial.contains("wind_speed_unit=mph"))
    }

    func testParseGeocode() throws {
        let data = #"{"results":[{"name":"Paris","latitude":48.85,"longitude":2.35,"country":"France"}]}"#.data(using: .utf8)!
        let place = try XCTUnwrap(GetWeatherTool.parseGeocode(data))
        XCTAssertEqual(place.name, "Paris")
        XCTAssertEqual(place.country, "France")
        XCTAssertEqual(place.label, "Paris, France")
        XCTAssertEqual(place.latitude, 48.85, accuracy: 0.01)
    }

    func testParseGeocodeEmptyResults() throws {
        XCTAssertNil(try GetWeatherTool.parseGeocode(#"{"results":[]}"#.data(using: .utf8)!))
        XCTAssertNil(try GetWeatherTool.parseGeocode(#"{}"#.data(using: .utf8)!))
    }

    func testParseWeather() throws {
        let place = GetWeatherTool.Place(name: "Paris", country: "France", latitude: 48.85, longitude: 2.35)
        let data = #"{"current":{"temperature_2m":12.3,"apparent_temperature":10.1,"relative_humidity_2m":80,"weather_code":3,"wind_speed_10m":15.2}}"#.data(using: .utf8)!
        let text = try GetWeatherTool.parseWeather(data, place: place, units: .metric)
        XCTAssertTrue(text.contains("Paris, France"))
        XCTAssertTrue(text.contains("12.3°C"))
        XCTAssertTrue(text.contains("overcast"))
        XCTAssertTrue(text.contains("80%"))
        XCTAssertTrue(text.contains("15.2 km/h"))
    }

    func testWeatherCodeDescriptions() {
        XCTAssertEqual(GetWeatherTool.description(for: 0), "clear sky")
        XCTAssertEqual(GetWeatherTool.description(for: 3), "overcast")
        XCTAssertEqual(GetWeatherTool.description(for: 95), "thunderstorm")
    }

    func testGetWeatherValidatesCity() {
        XCTAssertThrowsError(try GetWeatherTool().validate(.object([:])))
        XCTAssertThrowsError(try GetWeatherTool().validate(.object(["city": .string("   ")])))
        XCTAssertNoThrow(try GetWeatherTool().validate(.object(["city": .string("Paris")])))
    }

    // MARK: - web_search

    func testWebSearchFormat() {
        let results = [
            WebSearch.Result(title: "First", url: "https://a.example", snippet: "snip a"),
            WebSearch.Result(title: "Second", url: "https://b.example", snippet: "")
        ]
        let text = WebSearchTool.format(results)
        XCTAssertTrue(text.contains("1. First"))
        XCTAssertTrue(text.contains("https://a.example"))
        XCTAssertTrue(text.contains("snip a"))
        XCTAssertTrue(text.contains("2. Second"))
    }

    func testWebSearchValidatesQuery() {
        XCTAssertThrowsError(try WebSearchTool().validate(.object([:])))
        XCTAssertNoThrow(try WebSearchTool().validate(.object(["query": .string("cats")])))
    }

    func testWebSearchUnconfiguredThrowsBeforeNetwork() async {
        do {
            _ = try await WebSearchTool().execute(.object(["query": .string("cats")]))
            XCTFail("Expected an unconfigured error")
        } catch let error as ToolError {
            XCTAssertTrue(error.localizedDescription.contains("not set up"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - fetch_url

    func testFetchURLAcceptsHTTPAndHTTPS() {
        XCTAssertNoThrow(try FetchURLTool.validateURL("https://example.com/page", config: FetchURLConfig()))
        XCTAssertNoThrow(try FetchURLTool.validateURL("http://example.com", config: FetchURLConfig()))
    }

    func testFetchURLRejectsBadSchemes() {
        for bad in ["ftp://example.com", "file:///etc/passwd", "data:text/html,hi", "example.com"] {
            XCTAssertThrowsError(try FetchURLTool.validateURL(bad, config: FetchURLConfig()), bad)
        }
        XCTAssertThrowsError(try FetchURLTool.validateURL(nil, config: FetchURLConfig()))
        XCTAssertThrowsError(try FetchURLTool.validateURL("   ", config: FetchURLConfig()))
    }

    func testFetchURLHostAllowAndBlockLists() {
        let blocked = FetchURLConfig(blockedHosts: ["evil.com"])
        XCTAssertThrowsError(try FetchURLTool.validateURL("https://evil.com/x", config: blocked))
        XCTAssertThrowsError(try FetchURLTool.validateURL("https://sub.evil.com/x", config: blocked))
        XCTAssertNoThrow(try FetchURLTool.validateURL("https://ok.com", config: blocked))

        let allowOnly = FetchURLConfig(allowedHosts: ["example.com"])
        XCTAssertNoThrow(try FetchURLTool.validateURL("https://example.com", config: allowOnly))
        XCTAssertNoThrow(try FetchURLTool.validateURL("https://docs.example.com", config: allowOnly))
        XCTAssertThrowsError(try FetchURLTool.validateURL("https://other.com", config: allowOnly))
    }

    func testFetchURLLocalNetworkToggle() {
        let noLocal = FetchURLConfig(allowLocalNetwork: false)
        XCTAssertThrowsError(try FetchURLTool.validateURL("http://192.168.1.10:8080", config: noLocal))
        XCTAssertThrowsError(try FetchURLTool.validateURL("http://localhost:11434", config: noLocal))
        // Default config allows local reach (the deliberate relaxation).
        XCTAssertNoThrow(try FetchURLTool.validateURL("http://192.168.1.10:8080", config: FetchURLConfig()))
    }

    func testIsLocalHostMatrix() {
        for local in ["localhost", "127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1",
                      "172.31.255.255", "169.254.1.1", "::1", "myserver.local", "0.0.0.0"] {
            XCTAssertTrue(FetchURLTool.isLocalHost(local), local)
        }
        for public_ in ["example.com", "8.8.8.8", "172.15.0.1", "172.32.0.1", "1.1.1.1"] {
            XCTAssertFalse(FetchURLTool.isLocalHost(public_), public_)
        }
    }

    // MARK: - retrieve_context

    func testRetrieveContextFormat() {
        let chunks = [
            RetrievableChunk(id: UUID(), sourceName: "notes.txt", ordinal: 0, text: "alpha"),
            RetrievableChunk(id: UUID(), sourceName: "notes.txt", ordinal: 1, text: "beta", filePath: "docs/b.md")
        ]
        let text = RetrieveContextTool.format(chunks)
        XCTAssertTrue(text.contains("[notes.txt]\nalpha"))
        XCTAssertTrue(text.contains("[docs/b.md]\nbeta"))   // displaySource prefers filePath
    }

    func testRetrieveContextValidatesQuery() {
        XCTAssertThrowsError(try RetrieveContextTool().validate(.object([:])))
        XCTAssertNoThrow(try RetrieveContextTool().validate(.object(["query": .string("x")])))
    }

    func testRetrieveContextNoSourcesThrows() async {
        do {
            _ = try await RetrieveContextTool().execute(.object(["query": .string("x")]))
            XCTFail("Expected a no-sources error")
        } catch let error as ToolError {
            XCTAssertTrue(error.localizedDescription.contains("No documents"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetrieveContextRanksRelevantChunkFirst() async throws {
        try XCTSkipIf(NLEmbedding.sentenceEmbedding(for: .english) == nil, "NLEmbedding unavailable")
        let chunks = [
            RetrievableChunk(id: UUID(), sourceName: "sci", ordinal: 0,
                             text: "The mitochondria is the powerhouse of the cell."),
            RetrievableChunk(id: UUID(), sourceName: "geo", ordinal: 1,
                             text: "Paris is the capital of France and sits on the Seine.")
        ]
        let tool = RetrieveContextTool(chunks: chunks, maxTokens: 1000)
        let result = try await tool.execute(.object(["query": .string("What is the capital of France?"),
                                                     "count": .number(1)]))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Paris"))
        XCTAssertFalse(result.content.contains("mitochondria"))
    }
}
