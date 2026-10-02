import Foundation
import SwiftUI

/// The live scrolling pitch graph, redrawn at up to 60 fps while listening.
struct LivePitchGraph: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    /// Draws raw YIN estimates as dots (used on the debug screen).
    var showsRawEstimates = false

    var body: some View {
        let isRunning = monitor.status.isRunning
        let target = monitor.targetZone
        // Reading the revision makes a paused graph redraw after a reset.
        let _ = monitor.historyRevision

        // 60 fps is smooth for a scrolling line; ProMotion's 120 Hz would
        // double the drawing for no visible gain (30 fps in Low Power Mode).
        let interval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 30 : 1.0 / 60
        TimelineView(.animation(minimumInterval: interval, paused: !isRunning)) { context in
            let end = monitor.graphEndTime(at: context.date)
            PitchGraphCanvas(
                points: monitor.graphPoints(endingAt: end),
                windowEnd: end,
                duration: monitor.graphDuration,
                target: target,
                showsRawEstimates: showsRawEstimates
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pitch graph, last \(Int(monitor.graphDuration)) seconds")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let target = monitor.targetZone
        guard let frequency = monitor.readoutFrequency else {
            return "No voice detected. Target zone \(target.spokenDescription)."
        }
        let hertz = frequency.roundedInt
        let position: String
        if target.contains(frequency) {
            position = "inside the target zone"
        } else if frequency < target.lowerBound {
            position = "below the target zone"
        } else {
            position = "above the target zone"
        }
        return "Current pitch \(hertz) hertz, \(position) of \(target.spokenDescription)."
    }
}

/// Draws pitch points over time with a shaded target band.
struct PitchGraphCanvas: View {
    let points: [PitchGraphPoint]
    /// Time (seconds) at the right edge.
    let windowEnd: Double
    /// Seconds shown across the width.
    let duration: Double
    let target: PitchTargetZone
    var showsRawEstimates = false

    /// Longer gaps than this between points break the line (e.g. between words).
    private static let maximumGap = 0.06

    private struct GraphColors {
        let line: Color
        let zone: Color
        let markerOutline: Color
    }

    var body: some View {
        let scale = PitchGraphScale(target: target)
        let colors = GraphColors(
            line: Theme.pitchLine,
            zone: Theme.targetZone,
            markerOutline: Theme.cardBackground
        )

        Canvas { context, size in
            draw(in: &context, size: size, scale: scale, colors: colors)
        }
    }

    private func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        scale: PitchGraphScale,
        colors: GraphColors
    ) {
        let lineColor = colors.line
        let zoneColor = colors.zone
        guard size.width > 1, size.height > 1, duration > 0 else { return }

        // Grid labels sit in a right-hand gutter sized to the (Dynamic Type) text.
        let labels = scale.gridFrequencies.map { frequency in
            (frequency, context.resolve(
                Text("\(Int(frequency)) Hz")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            ))
        }
        let widestLabel = labels.map { $0.1.measure(in: size).width }.max() ?? 0
        let gutter = widestLabel + 8
        let plot = CGRect(x: 0, y: 6, width: max(1, size.width - gutter), height: max(1, size.height - 12))

        func yPosition(_ frequency: Double) -> CGFloat {
            plot.maxY - CGFloat(scale.position(for: frequency)) * plot.height
        }
        func xPosition(_ time: Double) -> CGFloat {
            plot.maxX - CGFloat((windowEnd - time) / duration) * plot.width
        }

        // Horizontal grid lines with labels.
        for (frequency, label) in labels {
            let y = yPosition(frequency)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            context.draw(label, at: CGPoint(x: size.width, y: y), anchor: .trailing)
        }

        // Target zone: shaded band with dashed edges and a text label,
        // so it's identifiable without relying on color.
        let top = yPosition(target.upperBound)
        let bottom = yPosition(target.lowerBound)
        let band = CGRect(x: plot.minX, y: top, width: plot.width, height: max(1, bottom - top))
        context.fill(Path(band), with: .color(zoneColor.opacity(0.16)))
        var edges = Path()
        edges.move(to: CGPoint(x: plot.minX, y: top))
        edges.addLine(to: CGPoint(x: plot.maxX, y: top))
        edges.move(to: CGPoint(x: plot.minX, y: bottom))
        edges.addLine(to: CGPoint(x: plot.maxX, y: bottom))
        context.stroke(edges, with: .color(zoneColor), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        let bandLabel = context.resolve(
            Text("Target \(target.formatted)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(zoneColor)
        )
        context.draw(bandLabel, at: CGPoint(x: plot.minX + 6, y: top + 3), anchor: .topLeading)

        // Everything below is data, clipped to the plot area.
        var plotContext = context
        plotContext.clip(to: Path(plot))

        if showsRawEstimates {
            var dots = Path()
            for point in points {
                guard let raw = point.rawFrequency else { continue }
                let center = CGPoint(x: xPosition(point.time), y: yPosition(raw))
                dots.addEllipse(in: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
            }
            plotContext.fill(dots, with: .color(.secondary.opacity(0.6)))
        }

        // The pitch line, broken wherever the voice stopped.
        var line = Path()
        var previous: PitchGraphPoint?
        var lastDrawn: PitchGraphPoint?
        for point in points {
            guard let frequency = point.frequency else {
                previous = nil
                continue
            }
            let location = CGPoint(x: xPosition(point.time), y: yPosition(frequency))
            if let previous, point.time - previous.time <= Self.maximumGap {
                line.addLine(to: location)
            } else {
                line.move(to: location)
            }
            previous = point
            lastDrawn = point
        }
        plotContext.stroke(
            line,
            with: .color(lineColor),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        )

        // A dot marks the live position while the voice is sounding.
        if let lastDrawn, let frequency = lastDrawn.frequency, windowEnd - lastDrawn.time < 0.15 {
            let center = CGPoint(x: xPosition(lastDrawn.time), y: yPosition(frequency))
            let marker = Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
            plotContext.fill(marker, with: .color(lineColor))
            plotContext.stroke(marker, with: .color(colors.markerOutline), lineWidth: 2)
        }
    }
}
