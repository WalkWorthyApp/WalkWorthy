//
//  SentimentChartView.swift
//  WalkWorthy
//

import SwiftUI
import Charts

struct SentimentChartView: View {
    let summaries: [DailyMoodSummary]
    let daysToDisplay: [String]   // ISO date strings in chronological order

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Only days that actually have data, in chronological order
    private var chartPoints: [(date: Date, value: Double, color: Color)] {
        daysToDisplay.compactMap { dateString in
            guard
                let summary = summaries.first(where: { $0.date == dateString }),
                let date = Self.isoFormatter.date(from: dateString)
            else { return nil }

            let value: Double
            let color: Color
            switch summary.overallSentiment {
            case "positive":
                value = 3; color = Color(red: 0.4, green: 0.7, blue: 0.4)
            case "neutral":
                value = 2; color = Color(red: 0.95, green: 0.7, blue: 0.3)
            case "challenging":
                value = 1; color = Color(red: 0.85, green: 0.4, blue: 0.4)
            default:
                return nil
            }
            return (date: date, value: value, color: color)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if chartPoints.isEmpty {
                Text("No check-ins to chart yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
            } else {
                Chart {
                    ForEach(Array(chartPoints.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Sentiment", point.value)
                        )
                        .foregroundStyle(Color(.systemGray3))
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Sentiment", point.value)
                        )
                        .foregroundStyle(point.color)
                        .symbolSize(80)
                    }
                }
                .chartYScale(domain: 0.5...3.5)
                .chartYAxis {
                    AxisMarks(values: [1.0, 2.0, 3.0]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            switch value.as(Double.self) {
                            case 3: Text("Positive").font(.caption2).foregroundStyle(Color(red: 0.4, green: 0.7, blue: 0.4))
                            case 2: Text("Neutral").font(.caption2).foregroundStyle(Color(red: 0.95, green: 0.7, blue: 0.3))
                            case 1: Text("Hard").font(.caption2).foregroundStyle(Color(red: 0.85, green: 0.4, blue: 0.4))
                            default: EmptyView()
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day())
                    }
                }
                .frame(height: 160)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
    }
}
