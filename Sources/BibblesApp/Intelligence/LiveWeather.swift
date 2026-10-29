import Foundation

/// A weather question such as "what is the temp in Delhi", "weather in New
/// York tomorrow" or "kal Mumbai ka mausam kaisa hoga".
struct WeatherQuery: Equatable {
    let city: String
    let tomorrow: Bool
    /// The question's language (ISO-639-1), set only by the multilingual
    /// Tool Gate path; nil keeps the original English behaviour.
    var language: String? = nil

    /// `multilingual`: also understand weather questions in other languages
    /// (on while the Tool Gate is on).
    static func parse(_ input: String, multilingual: Bool? = nil) -> WeatherQuery? {
        if let english = parseEnglish(input) { return english }
        guard multilingual ?? ToolGate.isEnabled else { return nil }
        return parseMultilingual(input)
    }

    private static func parseEnglish(_ input: String) -> WeatherQuery? {
        let text = input.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let weatherWords = #"\b(?:weather|temperature|temp|forecast|mausam|humidity|raining|rainy|barish|baarish|how hot|how cold|kitni garmi|kitni thand)\b"#
        guard text.range(of: weatherWords, options: .regularExpression) != nil else { return nil }
        // Not about the outdoors: "CPU temperature", "temp folder".
        let notWeather = #"\b(?:cpu|gpu|mac|macbook|laptop|battery|body|water|oven|folder|file|files|fever)\b"#
        guard text.range(of: notWeather, options: .regularExpression) == nil else { return nil }

        let tomorrow = text.range(of: #"\b(?:tomorrow|kal)\b"#, options: .regularExpression) != nil
        let candidates = [
            // English: "... in Delhi", "... at Delhi", "... for New Delhi tomorrow"
            capture(#"\b(?:in|at|for|of|near)\s+([\p{L} ]+)$"#, in: text),
            // Hinglish: "Delhi ka mausam", "kal Mumbai mein weather kaisa hoga"
            capture(#"^([\p{L} ]+?)\s+(?:ka|ki|ke|mein|me|mai|main)\s+(?:aaj |kal |abhi )?(?:weather|mausam|temperature|temp|forecast|kitni garmi|kitni thand|barish|baarish)\b"#, in: text)
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let city = cleanCity(candidate) { return WeatherQuery(city: city, tomorrow: tomorrow) }
        }
        return nil
    }

    /// "Wetter in Berlin", "météo à Paris", "tiempo en Madrid", "दिल्ली का मौसम",
    /// "東京の天気". Nil when unsure (the question then goes to a web search).
    static func parseMultilingual(_ input: String) -> WeatherQuery? {
        let language = ToolGate.detectLanguage(input)
        // English and Hinglish keep their original rules (parseEnglish).
        if ["en", "hinglish"].contains(language.code), language.confidence >= 0.6 { return nil }
        let padded = ToolGateText.padded(input)
        guard ToolGate.matches(ToolGateLexicon.weather, in: padded, language: language) else { return nil }
        let words = padded.split(separator: " ").map(String.init)
        // Spanish "tiempo en" also means time spent somewhere. Treat it as
        // weather only when it starts the request or has a weather-question
        // lead-in ("qué tiempo", "dime el tiempo", etc.).
        if language.code == "es", let index = words.firstIndex(of: "tiempo"),
           words.dropFirst(index + 1).first == "en" {
            let leadIn = Set(words[..<index])
            let weatherLeadIn = ToolGateText.foldSet(["qué", "que", "el", "dime", "dígame", "cuál", "cual", "cómo", "como", "hace"])
            guard index == 0 || !leadIn.isDisjoint(with: weatherLeadIn) else { return nil }
        }
        // Not about the outdoors (CPU temperature, a body temperature…).
        let notWeather = ToolGateText.foldSet(["cpu", "gpu", "mac", "macbook", "laptop", "battery", "akku", "batterie",
                                               "batería", "batteria", "bateria", "body", "körper", "fieber", "fièvre",
                                               "fiebre", "febbre", "febre", "water", "wasser", "eau", "agua", "acqua"])
        guard words.count <= 12, Set(words).isDisjoint(with: notWeather) else { return nil }
        let tomorrowWords = ToolGateText.foldSet(["tomorrow", "morgen", "demain", "mañana", "domani", "amanhã", "kal",
                                                  "कल", "yarın", "завтра", "غدا", "明日", "내일", "jutro", "imorgon",
                                                  "zítra", "utre", "утре", "huomenna", "sutra", "zajtra", "明天", "holnap",
                                                  "mâine", "homme"])
        let tomorrow = !Set(words).isDisjoint(with: tomorrowWords) || ["明日", "明天", "내일"].contains(where: { input.contains($0) })
        let code = language.answerLanguage == "und" ? nil : language.answerLanguage

        // Single weather words, so they are never taken for the city.
        let weatherWords = Set(ToolGateText.foldedTable(ToolGateLexicon.weather).values.joined()
            .flatMap { $0.split(separator: " ").map(String.init) })
        let stop = weatherWords.union(ToolGateLexicon.weatherFiller).union(ToolGateLexicon.placePrepositions)
            .union(tomorrowWords).union(ToolGateText.foldSet(["what", "how", "is", "es", "ist", "wie", "was", "quel", "quelle",
                                                             "qué", "que", "como", "cómo", "come", "che", "hoe", "wat",
                                                             "kaisa", "kaisi", "hai", "का", "की", "के", "में", "है", "कैसा",
                                                             "कैसी", "आज", "क्या", "fa", "faz", "va", "il", "vai"]))
        let shown = input.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\p{M}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        let pointing = Set(ToolGateText.foldedTable(ToolGateLexicon.deictic).values.joined())
        func city(from range: Range<Int>) -> String? {
            // Single Latin letters ("s" from "what's") are never a city.
            let indices = range.filter { !stop.contains(words[$0]) && !(words[$0].count == 1 && words[$0].first!.isASCII) }
            guard indices.allSatisfy({ !pointing.contains(words[$0]) }) else { return nil }
            guard (1...3).contains(indices.count),
                  indices.last! - indices.first! == indices.count - 1 else { return nil }
            let deictic = ToolGateText.foldSet(["here", "hier", "ici", "aquí", "qui", "aqui", "yahan", "यहाँ", "my", "mein", "mon", "mi", "mio", "meu"])
            guard indices.allSatisfy({ !deictic.contains(words[$0]) }) else { return nil }
            let source = shown.count == words.count ? shown : words
            return indices.map { source[$0].prefix(1).uppercased() + source[$0].dropFirst() }.joined(separator: " ")
        }
        // 1. After the last place preposition: "in Berlin", "à Paris", "en Madrid".
        if let last = words.lastIndex(where: { ToolGateLexicon.placePrepositions.contains($0) }), last + 1 < words.count,
           let name = city(from: (last + 1)..<words.count) {
            return WeatherQuery(city: name, tomorrow: tomorrow, language: code)
        }
        // 2. Before a possessive: "दिल्ली का मौसम", "Mumbai ka mausam".
        if let mark = words.firstIndex(where: { ["का", "की", "के", "में", "ka", "ki", "ke", "mein"].contains($0) }), mark > 0,
           let name = city(from: 0..<mark) {
            return WeatherQuery(city: name, tomorrow: tomorrow, language: code)
        }
        // 3. Chinese/Japanese/Korean: the place before the weather word.
        for marker in ["の天気", "的天气", "的天氣", "天气", "天氣", "天気", " 날씨", "날씨"] {
            if let range = input.range(of: marker) {
                var place = String(input[..<range.lowerBound])
                for particle in ["今日", "明日", "今天", "明天", "오늘", "내일", "の", "的", "は"] {
                    place = place.replacingOccurrences(of: particle, with: "")
                }
                place = place.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if !place.isEmpty, place.count <= 12 { return WeatherQuery(city: place, tomorrow: tomorrow, language: code) }
            }
        }
        // 4. Whatever is left after the weather words: "Wetter Berlin".
        return city(from: 0..<words.count).map { WeatherQuery(city: $0, tomorrow: tomorrow, language: code) }
    }

    private static let filler: Set<String> = [
        "today", "tomorrow", "tonight", "now", "right", "currently", "current", "this", "week", "morning",
        "evening", "the", "city", "please", "aaj", "kal", "abhi", "weather", "temperature", "temp",
        "mausam", "forecast", "kaisa", "kaisi", "kaise", "hai", "hoga", "hogi", "rahega", "what", "s", "is",
        "like", "outside", "going", "to", "be", "there", "it", "how", "hot", "cold", "bata", "batao", "of", "in", "at", "for", "near"
    ]

    private static func cleanCity(_ raw: String) -> String? {
        var words = raw.split(separator: " ").map(String.init)
        while let first = words.first, filler.contains(first) { words.removeFirst() }
        while let last = words.last, filler.contains(last) { words.removeLast() }
        guard (1...4).contains(words.count), !words.contains(where: { ["my", "here", "yahan"].contains($0) }) else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}

/// Live weather from Open-Meteo: exact figures, no AI model and no web search.
///
/// Note: Open-Meteo's free API is for non-commercial use. Before selling
/// Bibbles, move to their commercial plan (set `apiKey`).
enum LiveWeather {
    static let label = "Live weather"
    /// A commercial Open-Meteo key, if you have one.
    static var apiKey: String? {
        let value = ProcessInfo.processInfo.environment["BIBBLES_OPENMETEO_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    struct Reply {
        let text: String
        let source: WebSearchSource
    }

    /// Nil when the city isn't found or the service can't be reached, so the
    /// question falls back to a normal web search.
    static func answer(for query: WeatherQuery, session: URLSession = .shared,
                       locale: Locale = .current) async -> Reply? {
        let region = (locale as NSLocale).object(forKey: .countryCode) as? String
        guard let place = await geocode(query.city, preferring: region, language: query.language ?? "en", session: session),
              let forecast = await forecast(for: place, fahrenheit: usesFahrenheit(locale: locale), session: session) else { return nil }
        let text = query.language.map { describe(forecast, place: place, tomorrow: query.tomorrow, language: $0) }
            ?? describe(forecast, place: place, tomorrow: query.tomorrow)
        let source = WebSearchSource(title: "Open-Meteo weather for \(place.name)",
                                     url: URL(string: "https://open-meteo.com/")!)
        return Reply(text: text, source: source)
    }

    struct Place: Equatable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    struct Forecast: Equatable {
        var unit: String
        var current: Double?
        var feelsLike: Double?
        var humidity: Double?
        var code: Int?
        var todayMax: Double?
        var todayMin: Double?
        var todayRain: Double?
        var tomorrowMax: Double?
        var tomorrowMin: Double?
        var tomorrowRain: Double?
        var tomorrowCode: Int?
    }

    private static func host(_ name: String) -> String {
        apiKey == nil ? name : "customer-" + name
    }

    /// °F for the United States (and, with the Tool Gate on, the few other
    /// places that use it); °C everywhere else.
    static func usesFahrenheit(locale: Locale, extended: Bool? = nil) -> Bool {
        let region = (locale as NSLocale).object(forKey: .countryCode) as? String ?? ""
        if region == "US" { return true }
        guard extended ?? ToolGate.isEnabled else { return false }
        return ["LR", "MM", "BS", "BZ", "KY", "PW", "FM", "MH", "PR", "GU", "VI", "AS", "MP"].contains(region)
    }

    private static func geocode(_ city: String, preferring region: String?, language: String = "en",
                                session: URLSession) async -> Place? {
        var components = URLComponents(string: "https://\(host("geocoding-api.open-meteo.com"))/v1/search")!
        var items = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "5"),
                     URLQueryItem(name: "language", value: language), URLQueryItem(name: "format", value: "json")]
        if let apiKey { items.append(URLQueryItem(name: "apikey", value: apiKey)) }
        components.queryItems = items
        guard let url = components.url,
              let object = await json(url, session: session),
              let results = object["results"] as? [[String: Any]], !results.isEmpty else { return nil }
        // "Delhi" also exists in the US: prefer a match in the user's own country.
        let chosen = results.first { ($0["country_code"] as? String) == region } ?? results[0]
        guard let latitude = (chosen["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (chosen["longitude"] as? NSNumber)?.doubleValue else { return nil }
        return Place(name: chosen["name"] as? String ?? city, latitude: latitude, longitude: longitude)
    }

    private static func forecast(for place: Place, fahrenheit: Bool, session: URLSession) async -> Forecast? {
        var components = URLComponents(string: "https://\(host("api.open-meteo.com"))/v1/forecast")!
        var items = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        if fahrenheit { items.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit")) }
        if let apiKey { items.append(URLQueryItem(name: "apikey", value: apiKey)) }
        components.queryItems = items
        guard let url = components.url, let object = await json(url, session: session) else { return nil }
        return parseForecast(object, fahrenheit: fahrenheit)
    }

    static func parseForecast(_ object: [String: Any], fahrenheit: Bool) -> Forecast? {
        let current = object["current"] as? [String: Any] ?? [:]
        let daily = object["daily"] as? [String: Any] ?? [:]
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        func day(_ key: String, _ index: Int) -> Double? {
            guard let values = daily[key] as? [Any], values.count > index else { return nil }
            return number(values[index])
        }
        var forecast = Forecast(unit: fahrenheit ? "°F" : "°C")
        forecast.current = number(current["temperature_2m"])
        forecast.feelsLike = number(current["apparent_temperature"])
        forecast.humidity = number(current["relative_humidity_2m"])
        forecast.code = number(current["weather_code"]).map { Int($0) } ?? day("weather_code", 0).map { Int($0) }
        forecast.todayMax = day("temperature_2m_max", 0)
        forecast.todayMin = day("temperature_2m_min", 0)
        forecast.todayRain = day("precipitation_probability_max", 0)
        forecast.tomorrowMax = day("temperature_2m_max", 1)
        forecast.tomorrowMin = day("temperature_2m_min", 1)
        forecast.tomorrowRain = day("precipitation_probability_max", 1)
        forecast.tomorrowCode = day("weather_code", 1).map { Int($0) }
        guard forecast.current != nil || forecast.todayMax != nil else { return nil }
        return forecast
    }

    static func describe(_ forecast: Forecast, place: Place, tomorrow: Bool) -> String {
        let unit = forecast.unit
        func degrees(_ value: Double?) -> String? { value.map { "\(Int($0.rounded()))\(unit)" } }
        func rain(_ value: Double?) -> String {
            guard let value else { return "" }
            return ", \(Int(value.rounded()))% chance of rain"
        }
        if tomorrow, let high = degrees(forecast.tomorrowMax), let low = degrees(forecast.tomorrowMin) {
            let sky = forecast.tomorrowCode.map { ", " + condition($0) } ?? ""
            return "Tomorrow in \(place.name): \(low) to \(high)\(sky)\(rain(forecast.tomorrowRain))."
        }
        var parts: [String] = []
        if let now = degrees(forecast.current) {
            var sentence = "Right now in \(place.name) it's \(now)"
            if let feels = degrees(forecast.feelsLike), feels != now { sentence += " (feels like \(feels))" }
            if let code = forecast.code { sentence += " and " + condition(code) }
            if let humidity = forecast.humidity { sentence += ", with \(Int(humidity.rounded()))% humidity" }
            parts.append(sentence + ".")
        }
        if let high = degrees(forecast.todayMax), let low = degrees(forecast.todayMin) {
            parts.append("Today: \(low) to \(high)\(rain(forecast.todayRain)).")
        }
        return parts.joined(separator: " ")
    }

    /// The weather in the user's language (German, French, Spanish, Italian,
    /// Portuguese, Dutch; English otherwise).
    static func describe(_ forecast: Forecast, place: Place, tomorrow: Bool, language: String) -> String {
        guard ToolGateStrings.weatherLanguages.contains(language) else {
            return describe(forecast, place: place, tomorrow: tomorrow)
        }
        let unit = forecast.unit
        func degrees(_ value: Double?) -> String? { value.map { "\(Int($0.rounded()))\(unit)" } }
        func rain(_ value: Double?) -> Int? { value.map { Int($0.rounded()) } }
        if tomorrow, let high = degrees(forecast.tomorrowMax), let low = degrees(forecast.tomorrowMin) {
            return ToolGateStrings.weatherRange(low: low, high: high, rain: rain(forecast.tomorrowRain), tomorrow: true,
                                                place: place.name,
                                                condition: forecast.tomorrowCode.map { ToolGateStrings.condition($0, language: language) },
                                                language: language)
        }
        var parts: [String] = []
        if let now = degrees(forecast.current) {
            parts.append(ToolGateStrings.weatherNow(place: place.name, now: now,
                                                    condition: forecast.code.map { ToolGateStrings.condition($0, language: language) },
                                                    language: language))
        }
        if let high = degrees(forecast.todayMax), let low = degrees(forecast.todayMin) {
            parts.append(ToolGateStrings.weatherRange(low: low, high: high, rain: rain(forecast.todayRain), tomorrow: false,
                                                      place: place.name, condition: nil, language: language))
        }
        return parts.joined(separator: " ")
    }

    /// WMO weather codes in plain words.
    static func condition(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "cloudy"
        case 45, 48: return "foggy"
        case 51, 53, 55: return "drizzling"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81: return "rain showers"
        case 82: return "heavy rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorms"
        case 96, 99: return "thunderstorms with hail"
        default: return "mixed weather"
        }
    }

    private static func json(_ url: URL, session: URLSession) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let result = try? await session.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
    }
}
