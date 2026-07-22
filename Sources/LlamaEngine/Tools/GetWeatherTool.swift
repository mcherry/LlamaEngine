import Foundation

/// Current weather for a city, via Open-Meteo. `network`, but a *low-risk* network tool:
/// the hosts are hardcoded (`geocoding-api.open-meteo.com` + `api.open-meteo.com`), the API
/// is keyless, and it is GET-only — the safe fixed-endpoint pattern, not an arbitrary URL.
/// URL-building and response-parsing are pure static functions so they unit-test with fixtures.
public struct GetWeatherTool: AgentTool {
    public init() {}

    public let name = "get_weather"
    public let description = "Returns the current weather for a city (temperature, conditions, humidity, wind)."
    public let riskTier: ToolRiskTier = .network

    public var parameters: JSONSchema {
        .object(properties: [
            "city": .object([
                "type": .string("string"),
                "description": .string("City name, optionally with a region or country, e.g. \"Paris\" or \"Portland, Oregon\".")
            ]),
            "units": .object([
                "type": .string("string"),
                "description": .string("\"metric\" (Celsius, km/h) or \"imperial\" (Fahrenheit, mph). Defaults to metric.")
            ])
        ], required: ["city"])
    }

    public func validate(_ arguments: JSONValue) throws {
        guard let city = arguments.string("city")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !city.isEmpty else {
            throw ToolError.invalidArgument("Provide a city name.")
        }
    }

    public func execute(_ arguments: JSONValue) async throws -> ToolResult {
        let city = (arguments.string("city") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else { throw ToolError.invalidArgument("Provide a city name.") }
        let units = Units(rawValue: (arguments.string("units") ?? "metric").lowercased()) ?? .metric

        let geoData = try await Self.get(Self.geocodeURL(city: city))
        guard let place = try Self.parseGeocode(geoData) else {
            throw ToolError.executionFailed("No location found for \"\(city)\".")
        }
        let weatherData = try await Self.get(Self.forecastURL(latitude: place.latitude,
                                                              longitude: place.longitude, units: units))
        let summary = try Self.parseWeather(weatherData, place: place, units: units)
        return ToolResult(content: summary, displaySummary: "Weather for \(place.label)")
    }

    // MARK: - Pure helpers

    public enum Units: String, Sendable {
        case metric, imperial
        var temperatureUnit: String { self == .imperial ? "fahrenheit" : "celsius" }
        var windUnit: String { self == .imperial ? "mph" : "kmh" }
        var temperatureSymbol: String { self == .imperial ? "°F" : "°C" }
        var windSymbol: String { self == .imperial ? "mph" : "km/h" }
    }

    public struct Place: Sendable, Equatable {
        public let name: String
        public let country: String
        public let latitude: Double
        public let longitude: Double
        public var label: String { country.isEmpty ? name : "\(name), \(country)" }
    }

    static func geocodeURL(city: String) -> URL {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: city),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        return components.url!
    }

    static func forecastURL(latitude: Double, longitude: Double, units: Units) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "temperature_unit", value: units.temperatureUnit),
            URLQueryItem(name: "wind_speed_unit", value: units.windUnit)
        ]
        return components.url!
    }

    static func parseGeocode(_ data: Data) throws -> Place? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let name = first["name"] as? String,
              let latitude = (first["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (first["longitude"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let country = first["country"] as? String ?? ""
        return Place(name: name, country: country, latitude: latitude, longitude: longitude)
    }

    static func parseWeather(_ data: Data, place: Place, units: Units) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any] else {
            throw ToolError.executionFailed("Could not read the weather response.")
        }
        func number(_ key: String) -> Double? { (current[key] as? NSNumber)?.doubleValue }
        var lines = ["Current weather in \(place.label):"]
        if let code = (current["weather_code"] as? NSNumber)?.intValue {
            lines.append("Conditions: \(description(for: code))")
        }
        if let temperature = number("temperature_2m") {
            var line = "Temperature: \(format(temperature))\(units.temperatureSymbol)"
            if let feels = number("apparent_temperature") {
                line += " (feels like \(format(feels))\(units.temperatureSymbol))"
            }
            lines.append(line)
        }
        if let humidity = number("relative_humidity_2m") {
            lines.append("Humidity: \(Int(humidity))%")
        }
        if let wind = number("wind_speed_10m") {
            lines.append("Wind: \(format(wind)) \(units.windSymbol)")
        }
        return lines.joined(separator: "\n")
    }

    /// WMO weather-interpretation code to a short phrase (the codes Open-Meteo returns).
    static func description(for code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61, 63, 65: return "rain"
        case 66, 67: return "freezing rain"
        case 71, 73, 75: return "snowfall"
        case 77: return "snow grains"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "code \(code)"
        }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ToolError.executionFailed("The weather service returned an error.")
        }
        return data
    }
}
