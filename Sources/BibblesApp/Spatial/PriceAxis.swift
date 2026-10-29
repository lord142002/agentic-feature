import CoreGraphics
import Foundation

/// A support or resistance level drawn across a chart.
struct PriceLevel: Equatable {
    enum Kind: String { case support, resistance }

    let kind: Kind
    let price: Double
    let label: String
    /// Vertical position in normalized image coordinates (top-left origin).
    let y: CGFloat
    let xStart: CGFloat
    let xEnd: CGFloat
}

/// Maps prices to screen heights using the chart's price-scale labels read
/// by local OCR, so lines land exactly at a price instead of a model's guess.
struct PriceAxis: Equatable {
    /// y = slope * price + intercept (normalized image coordinates).
    let slope: Double
    let intercept: Double
    /// Left edge of the price labels; lines end just before it.
    let labelsLeftX: CGFloat

    func y(for price: Double) -> CGFloat {
        CGFloat(slope * price + intercept)
    }

    static func number(from text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "₹", with: "")
        guard cleaned.range(of: #"^[-+]?\d{1,7}(\.\d{1,8})?$"#, options: .regularExpression) != nil else { return nil }
        return Double(cleaned)
    }

    static func detect(in ocr: [OCRObservation]) -> PriceAxis? {
        // Numeric labels in the right part of the image are price-scale candidates.
        let candidates: [(x: CGFloat, left: CGFloat, y: CGFloat, price: Double)] = ocr.compactMap { item in
            let rect = item.normalizedRect
            let centerX = rect.x + rect.width / 2
            guard centerX > 0.55, let price = number(from: item.text) else { return nil }
            return (centerX, rect.x, rect.y + rect.height / 2, price)
        }
        guard candidates.count >= 3 else { return nil }

        // Group labels that share a column; the biggest column is the scale.
        let sorted = candidates.sorted { $0.x < $1.x }
        var columns: [[(x: CGFloat, left: CGFloat, y: CGFloat, price: Double)]] = []
        for item in sorted {
            if let last = columns.last?.last, abs(last.x - item.x) <= 0.025 {
                columns[columns.count - 1].append(item)
            } else {
                columns.append([item])
            }
        }
        guard let column = columns.max(by: { $0.count < $1.count }), column.count >= 3 else { return nil }

        // Robust fit: try every pair of labels, keep the line most labels
        // agree with (ignores other panes like an indicator's 0.0000 and
        // badges), then refine it with all agreeing labels.
        var best: [Int] = []
        for i in column.indices {
            for j in column.indices where j > i {
                let first = column[i], second = column[j]
                guard first.price != second.price else { continue }
                let slope = Double(second.y - first.y) / (second.price - first.price)
                guard slope < 0 else { continue } // higher prices sit higher on screen
                let intercept = Double(first.y) - slope * first.price
                let inliers = column.indices.filter {
                    abs(Double(column[$0].y) - (slope * column[$0].price + intercept)) <= 0.008
                }
                if inliers.count > best.count { best = inliers }
            }
        }
        let agreeing = best.map { column[$0] }
        guard agreeing.count >= 3, Set(agreeing.map { $0.price }).count >= 3,
              let fit = fit(agreeing), fit.slope < 0 else { return nil }
        return PriceAxis(slope: fit.slope, intercept: fit.intercept,
                         labelsLeftX: agreeing.map { $0.left }.min() ?? 0.95)
    }

    private static func fit(_ points: [(x: CGFloat, left: CGFloat, y: CGFloat, price: Double)]) -> (slope: Double, intercept: Double)? {
        let n = Double(points.count)
        let meanP = points.map { $0.price }.reduce(0, +) / n
        let meanY = points.map { Double($0.y) }.reduce(0, +) / n
        let variance = points.map { ($0.price - meanP) * ($0.price - meanP) }.reduce(0, +)
        guard variance > 0 else { return nil }
        let covariance = points.map { ($0.price - meanP) * (Double($0.y) - meanY) }.reduce(0, +)
        let slope = covariance / variance
        return (slope, meanY - slope * meanP)
    }
}
