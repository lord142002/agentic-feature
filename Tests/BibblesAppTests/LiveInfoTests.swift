import XCTest
@testable import BibblesApp

final class LiveInfoTests: XCTestCase {
    func testWeatherQuestionsFindTheCity() {
        XCTAssertEqual(WeatherQuery.parse("What is the temp in Delhi?"), WeatherQuery(city: "Delhi", tomorrow: false))
        XCTAssertEqual(WeatherQuery.parse("What's the weather in New York tomorrow?"), WeatherQuery(city: "New York", tomorrow: true))
        XCTAssertEqual(WeatherQuery.parse("kal Mumbai ka mausam kaisa hoga"), WeatherQuery(city: "Mumbai", tomorrow: true))
        XCTAssertEqual(WeatherQuery.parse("Is it raining in Pune right now"), WeatherQuery(city: "Pune", tomorrow: false))
        XCTAssertNil(WeatherQuery.parse("What's the weather?"))
        XCTAssertNil(WeatherQuery.parse("What is my CPU temperature?"))
        XCTAssertNil(WeatherQuery.parse("Explain weather vs climate"))
    }

    func testWeatherAnswerUsesExactFigures() throws {
        let object: [String: Any] = [
            "current": ["temperature_2m": 31.4, "apparent_temperature": 34.2, "relative_humidity_2m": 62, "weather_code": 2],
            "daily": ["temperature_2m_max": [33.6, 32.1], "temperature_2m_min": [24.2, 23.8],
                      "precipitation_probability_max": [10, 40], "weather_code": [2, 61]]
        ]
        let forecast = try XCTUnwrap(LiveWeather.parseForecast(object, fahrenheit: false))
        let place = LiveWeather.Place(name: "Delhi", latitude: 28.6, longitude: 77.2)
        XCTAssertEqual(LiveWeather.describe(forecast, place: place, tomorrow: false),
                       "Right now in Delhi it's 31°C (feels like 34°C) and partly cloudy, with 62% humidity. Today: 24°C to 34°C, 10% chance of rain.")
        XCTAssertEqual(LiveWeather.describe(forecast, place: place, tomorrow: true),
                       "Tomorrow in Delhi: 24°C to 32°C, light rain, 40% chance of rain.")
    }

    func testLiveQuestionsSearchTheWebWithoutTheWordSearch() {
        let router = IntentRouter()
        for question in ["What is the temp in Delhi", "Who won yesterday's IPL match", "Gold rate in Mumbai",
                         "USD to INR exchange rate", "Latest news headlines", "Bitcoin price"] {
            XCTAssertEqual(router.route(transcript: question, mode: .command), .search(query: question), question)
        }
        XCTAssertNotEqual(router.route(transcript: "What is this news article about?", mode: .command),
                          .search(query: "What is this news article about?"))
        XCTAssertEqual(router.route(transcript: "What is photosynthesis?", mode: .command), .chat(message: "What is photosynthesis?"))
    }

    func testPromptsKnowTheDate() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertTrue(ChatConversationStore.nowContext(now: date, timeZone: zone).contains("21 September 2026"))
        XCTAssertEqual(ChatConversationStore.searchDateHint(now: date, timeZone: zone), "today is 21 September 2026")
    }
}
