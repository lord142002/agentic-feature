import Foundation

enum ScreenQuestionKind: Equatable {
    case chartCandle
    case chartAnalysis
    case howTo
    case findControl
    case general

    static func classify(_ question: String) -> ScreenQuestionKind {
        let text = question.lowercased()
        // Every way of asking where something is gets the same treatment,
        // including "how do I find the X folder?" (a find, not a guide).
        let asksWhere = IntentRouter.isLocateRequest(text)
        if isHowTo(text), !asksWhere {
            return .howTo
        }
        if ["export", "download", "save as"].contains(where: text.contains) {
            return .findControl
        }
        if ["support", "resistance", "trendline", "trend line", "breakout", "price action", "rsi", "macd",
            "moving average", "fibonacci", "chart pattern", "analyse this chart", "analyze this chart", "this chart",
            "the chart", "chart analysis"].contains(where: text.contains) {
            return .chartAnalysis
        }
        if ["candle", "candlestick", "wick", "ohlc", "trading chart", "price bar"].contains(where: text.contains) {
            return .chartCandle
        }
        let findsOnScreen = ["find", "locate", "spot", "look for", "search for", "dhundo", "dhoondo"].contains(where: text.contains)
            && IntentRouter.refersToVisibleScreen(text)
        // "Can you see X?" — answer, and if X is there, point to it.
        let asksIfVisible = ["can you see", "can u see", "do you see", "do u see", "is there a", "is there any",
                             "are there any", "dikh raha", "dikh rahi", "dikhta hai"].contains(where: text.contains)
        if asksIfVisible || asksWhere { return .findControl }
        if findsOnScreen || ["where is", "where's", "where are", "how do i find", "how can i find", "locate the", "kahan", "kidhar"].contains(where: text.contains) {
            return .findControl
        }
        return .general
    }

    /// "How do I …", "steps to …", "guide me", "kaise …": a step-by-step guide.
    static func isHowTo(_ text: String) -> Bool {
        ["how do i", "how can i", "how to", "how would i", "how should i", "steps to", "step by step",
         "guide me", "walk me through", "show me how", "kaise kare", "kaise karu", "kaise karte", "kaise hota"]
            .contains(where: text.contains)
    }

    var expectsTarget: Bool {
        self == .findControl || self == .chartCandle
    }

    var prefersDisplayOverview: Bool {
        self == .findControl || self == .chartAnalysis || self == .howTo
    }

    var isChart: Bool {
        self == .chartCandle || self == .chartAnalysis
    }

    var needsOCR: Bool {
        self != .chartCandle
    }
}
