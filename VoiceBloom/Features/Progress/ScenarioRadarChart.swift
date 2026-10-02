import Accessibility
import Foundation
import SwiftUI

/// Average scenario scores per skill, drawn as a radar (spider) chart.
struct ScenarioRadarChart: View {
    let values: RadarValues?

    var body: some View {
        ChartCard(
            title: "Scenario skills",
            subtitle: values.map { "Average of \($0.resultCount) scenario\($0.resultCount == 1 ? "" : "s") in this range." }
        ) {
            if let values {
                RadarShapeView(values: values)
                    .frame(height: 260)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Scenario skills radar chart")
                    .accessibilityValue(RadarValues.Axis.allCases.compactMap { axis in
                        values.value(axis).map { "\(axis.title) \(Int($0.rounded()))" }
                    }.joined(separator: ", "))
                    // Lets VoiceOver users explore the values as an audio graph.
                    .accessibilityChartDescriptor(RadarChartDescriptor(values: values))
            } else {
                EmptyChartMessage(message: "Practice a scenario (More › Tools › Scenarios) to see your pitch, resonance, weight, intonation and consistency here.")
            }
        }
    }
}

/// The radar's values for VoiceOver's audio graphs and chart summary.
private nonisolated struct RadarChartDescriptor: AXChartDescriptorRepresentable {
    let values: RadarValues

    func makeChartDescriptor() -> AXChartDescriptor {
        let axes = RadarValues.Axis.allCases
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Skill", categoryOrder: axes.map(\.title))
        let yAxis = AXNumericDataAxisDescriptor(title: "Score", range: 0...100, gridlinePositions: [0, 25, 50, 75, 100]) { value in
            "\(Int(value.rounded())) out of 100"
        }
        let points = axes.compactMap { axis in
            values.value(axis).map { AXDataPoint(x: axis.title, y: $0) }
        }
        let series = AXDataSeriesDescriptor(name: "Average score", isContinuous: false, dataPoints: points)
        return AXChartDescriptor(
            title: "Scenario skills",
            summary: "Average scenario scores from 0 to 100 for each skill.",
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

private struct RadarShapeView: View {
    let values: RadarValues
    private let axes = RadarValues.Axis.allCases
    private let rings: [Double] = [0.25, 0.5, 0.75, 1]

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            // Leave room for the labels around the edge.
            let radius = max(10, min(geometry.size.width, geometry.size.height) / 2 - 34)

            ZStack {
                ForEach(rings, id: \.self) { ring in
                    polygon(center: center, radius: radius) { _ in ring }
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                }
                ForEach(Array(axes.enumerated()), id: \.offset) { index, _ in
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: point(index: index, fraction: 1, center: center, radius: radius))
                    }
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                }

                polygon(center: center, radius: radius) { axis in (values.value(axis) ?? 0) / 100 }
                    .fill(Theme.resonanceSeries.opacity(0.25))
                polygon(center: center, radius: radius) { axis in (values.value(axis) ?? 0) / 100 }
                    .stroke(Theme.resonanceSeries, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                ForEach(Array(axes.enumerated()), id: \.offset) { index, axis in
                    let fraction = (values.value(axis) ?? 0) / 100
                    Circle()
                        .fill(Theme.resonanceSeries)
                        .frame(width: 7, height: 7)
                        .position(point(index: index, fraction: fraction, center: center, radius: radius))
                    VStack(spacing: 0) {
                        Text(axis.title)
                            .font(.caption.weight(.medium))
                        Text(values.value(axis).map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .position(point(index: index, fraction: 1, center: center, radius: radius + 22))
                }
            }
        }
    }

    private func point(index: Int, fraction: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        // Start at the top and go clockwise.
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(axes.count)
        let distance = radius * CGFloat(min(max(fraction, 0), 1))
        return CGPoint(x: center.x + distance * CGFloat(cos(angle)), y: center.y + distance * CGFloat(sin(angle)))
    }

    private func polygon(center: CGPoint, radius: CGFloat, fraction: (RadarValues.Axis) -> Double) -> Path {
        Path { path in
            for (index, axis) in axes.enumerated() {
                let corner = point(index: index, fraction: fraction(axis), center: center, radius: radius)
                if index == 0 {
                    path.move(to: corner)
                } else {
                    path.addLine(to: corner)
                }
            }
            path.closeSubpath()
        }
    }
}
