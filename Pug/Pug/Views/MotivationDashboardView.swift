// MotivationDashboardView.swift
// Instrument-panel gauge dashboard shown at the top of each browser tab.
// Two speedometer-style gauges side by side: Vocab (left) and Grammar (right).
// Each gauge has an upper 270° arc (weekly quiz count) and a lower 90° arc
// (new items learned). Vertical labels and recall bars on the sides.
//
// Supports both dark and light color schemes. Dark mode has full neon glow;
// light mode reduces glow for readability.
//
// Tap to switch between the gauge view and a compact table view.

import SwiftUI

// MARK: - Top-level view

struct MotivationDashboardView: View {
    let db: QuizDB
    /// Increment this from the parent to trigger a data refresh (e.g. after quiz dismissal).
    let refreshID: Int

    @State private var snapshot: QuizDB.AnalyticsSnapshot? = nil
    @State private var isLoading = true
    @State private var showTable = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Group {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView().scaleEffect(0.75).tint(.white)
                    Spacer()
                }
                .frame(height: 140)
            } else if let s = snapshot {
                if showTable {
                    dashboardTable(s)
                        .onTapGesture { showTable.toggle() }
                } else {
                    gaugeRow(s)
                        .onTapGesture { showTable.toggle() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .task(id: refreshID) { await load() }
    }

    private func gaugeRow(_ s: QuizDB.AnalyticsSnapshot) -> some View {
        let isDark = colorScheme == .dark
        let cardBg = isDark ? Color(white: 0.07) : Color(white: 0.95)
        let vocabColor = Color(red: 0, green: 0.812, blue: 1)
        let vocabItemsColor = Color(red: 0.224, green: 1, blue: 0.561)
        let grammarColor = Color(red: 1, green: 0.549, blue: 0.259)
        let grammarItemsColor = Color(red: 0.780, green: 0.490, blue: 1)

        return HStack(spacing: 6) {
            // Leftmost: VOCAB text (vertical). fixedSize() lets Text render at its
            // natural un-wrapped width; rotationEffect is visual only; the outer
            // frame overrides the reported layout size so the HStack doesn't
            // reserve the full un-rotated text width and starve the gauges.
            Text("VOCAB")
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundColor(vocabColor)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 14, height: 60)

            // Vocab recall bar (vertical)
            recallBarVertical(s.vocabLowestRecall, color: vocabColor, isDark: isDark)
                .frame(width: 8)

            // Middle: two gauge canvases side by side
            HStack(spacing: 0) {
                GaugePanelView(
                    quizThisWeek:  s.vocabReviewsThisWeek,
                    quizLastWeek:  s.vocabReviewsLastWeek,
                    quizAllTimeMax: s.vocabReviewsAllTimeWeeklyMax,
                    quizColor:     vocabColor,
                    itemsThisWeek: s.vocabLearnedThisWeek,
                    itemsLastWeek: s.vocabLearnedLastWeek,
                    itemsAllTimeMax: s.vocabLearnedAllTimeWeeklyMax,
                    itemsColor:    vocabItemsColor,
                    weakestRecall: s.vocabLowestRecall,
                    hoursElapsed:  hoursElapsedThisWeek,
                    isDark:        isDark
                )
                GaugePanelView(
                    quizThisWeek:  s.grammarReviewsThisWeek,
                    quizLastWeek:  s.grammarReviewsLastWeek,
                    quizAllTimeMax: s.grammarReviewsAllTimeWeeklyMax,
                    quizColor:     grammarColor,
                    itemsThisWeek: s.grammarEnrolledThisWeek,
                    itemsLastWeek: s.grammarEnrolledLastWeek,
                    itemsAllTimeMax: s.grammarEnrolledAllTimeWeeklyMax,
                    itemsColor:    grammarItemsColor,
                    weakestRecall: s.grammarLowestRecall,
                    hoursElapsed:  hoursElapsedThisWeek,
                    isDark:        isDark
                )
            }

            // Grammar recall bar (vertical)
            recallBarVertical(s.grammarLowestRecall, color: grammarColor, isDark: isDark)
                .frame(width: 8)

            // Rightmost: GRAMMAR text (vertical)
            Text("GRAMMAR")
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundColor(grammarColor)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 14, height: 70)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(cardBg, in: RoundedRectangle(cornerRadius: 14))
    }

    private func recallBarVertical(_ recall: Double?, color: Color, isDark: Bool) -> some View {
        let barH = 60.0, barW = 5.0
        let trackOpacity: Double = isDark ? 0.12 : 0.18
        let filled = (recall ?? 0) * barH

        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill((isDark ? Color.white : Color.black).opacity(trackOpacity))
                .frame(width: barW, height: barH - filled)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color.opacity(isDark ? 0.85 : 0.75))
                .frame(width: barW, height: filled)
            Spacer()
        }
        .frame(height: barH)
    }

    private func dashboardTable(_ s: QuizDB.AnalyticsSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text("Vocab").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("Grammar").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            tableRow(
                label: "Weakest recall",
                vocabText: recallText(s.vocabLowestRecall),
                vocabColor: recallColor(s.vocabLowestRecall),
                grammarText: recallText(s.grammarLowestRecall),
                grammarColor: recallColor(s.grammarLowestRecall)
            )
            tableRow(
                label: "Quizzes this week",
                vocabText: weekText(thisWeek: s.vocabReviewsThisWeek, lastWeek: s.vocabReviewsLastWeek),
                vocabColor: weekColor(thisWeek: s.vocabReviewsThisWeek, lastWeek: s.vocabReviewsLastWeek),
                grammarText: weekText(thisWeek: s.grammarReviewsThisWeek, lastWeek: s.grammarReviewsLastWeek),
                grammarColor: weekColor(thisWeek: s.grammarReviewsThisWeek, lastWeek: s.grammarReviewsLastWeek)
            )
            tableRow(
                label: "Learned this week",
                vocabText: weekText(thisWeek: s.vocabLearnedThisWeek, lastWeek: s.vocabLearnedLastWeek),
                vocabColor: weekColor(thisWeek: s.vocabLearnedThisWeek, lastWeek: s.vocabLearnedLastWeek),
                grammarText: weekText(thisWeek: s.grammarEnrolledThisWeek, lastWeek: s.grammarEnrolledLastWeek),
                grammarColor: weekColor(thisWeek: s.grammarEnrolledThisWeek, lastWeek: s.grammarEnrolledLastWeek)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tableRow(
        label: String,
        vocabText: String, vocabColor: Color,
        grammarText: String, grammarColor: Color
    ) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(vocabText).font(.caption.monospacedDigit()).foregroundStyle(vocabColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(grammarText).font(.caption.monospacedDigit()).foregroundStyle(grammarColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func recallText(_ recall: Double?) -> String {
        guard let r = recall else { return "—" }
        return "\(Int((r * 100).rounded()))%"
    }

    private func recallColor(_ recall: Double?) -> Color {
        guard let r = recall else { return .secondary }
        if r < 0.05 { return .red }
        if r < 0.25 { return .orange }
        return .green
    }

    private func weekText(thisWeek: Int, lastWeek: Int) -> String {
        let arrow: String
        if thisWeek > lastWeek      { arrow = "↑" }
        else if thisWeek < lastWeek { arrow = "↓" }
        else                        { arrow = "=" }
        return "\(thisWeek) \(arrow)(\(lastWeek))"
    }

    private func weekColor(thisWeek: Int, lastWeek: Int) -> Color {
        if thisWeek > lastWeek { return .green }
        return .primary
    }

    private var hoursElapsedThisWeek: Double {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        return Date().timeIntervalSince(weekStart) / 3600
    }

    private func load() async {
        isLoading = snapshot == nil
        do {
            snapshot = try await db.analyticsSnapshot()
        } catch {
            print("[MotivationDashboardView] load failed: \(error)")
        }
        isLoading = false
    }
}

// MARK: - Single gauge panel (canvas only)

private struct GaugePanelView: View {
    let quizThisWeek: Int
    let quizLastWeek: Int
    let quizAllTimeMax: Int
    let quizColor: Color
    let itemsThisWeek: Int
    let itemsLastWeek: Int
    let itemsAllTimeMax: Int
    let itemsColor: Color
    let weakestRecall: Double?
    let hoursElapsed: Double
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            drawGauge(
                ctx: ctx, size: size,
                quizThisWeek:   Double(quizThisWeek),
                quizLastWeek:   Double(quizLastWeek),
                quizScaleMax:   Double(max(quizAllTimeMax, quizThisWeek, 1)),
                quizColor:      quizColor,
                itemsThisWeek:  Double(itemsThisWeek),
                itemsLastWeek:  Double(itemsLastWeek),
                itemsScaleMax:  Double(max(itemsAllTimeMax, itemsThisWeek, 1)),
                itemsColor:     itemsColor,
                weakestRecall:  weakestRecall,
                hoursElapsed:   hoursElapsed,
                isDark:         isDark
            )
        }
        .aspectRatio(220.0 / 205.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Geometry constants

private let svgCX     = 110.0
private let cyTop     = 102.0
private let cyBot     = 124.0
private let rTrackTop = 74.0
private let rNeedleTop     = 68.0
private let rPaceNeedleTop = 58.0
private let rTrackBot      = rTrackTop - (cyBot - cyTop)
private let rNeedleBot     = rTrackBot - (rTrackTop - rNeedleTop)
private let rPaceNeedleBot = rTrackBot - (rTrackTop - rPaceNeedleTop)
private let hubRadius  = 5.0

// MARK: - Drawing

private func drawGauge(
    ctx: GraphicsContext, size: CGSize,
    quizThisWeek: Double, quizLastWeek: Double, quizScaleMax: Double, quizColor: Color,
    itemsThisWeek: Double, itemsLastWeek: Double, itemsScaleMax: Double, itemsColor: Color,
    weakestRecall: Double?, hoursElapsed: Double, isDark: Bool
) {
    let sc = size.width / 220.0
    let cardBgColor = isDark ? Color(white: 0.07) : Color(white: 0.95)
    let glowBlur = isDark ? 3.0 : 1.5

    drawSubGauge(ctx: ctx, sc: sc, cx: svgCX, cy: cyTop, rTrack: rTrackTop, rNeedle: rNeedleTop, rPaceNeedle: rPaceNeedleTop,
        curValue: quizThisWeek, lastWeek: quizLastWeek, scaleMax: quizScaleMax,
        clockwiseOnScreen: true, angleFn: upperAngle, color: quizColor, hoursElapsed: hoursElapsed, cardBgColor: cardBgColor, glowBlur: glowBlur, isDark: isDark)
    drawSubGauge(ctx: ctx, sc: sc, cx: svgCX, cy: cyBot, rTrack: rTrackBot, rNeedle: rNeedleBot, rPaceNeedle: rPaceNeedleBot,
        curValue: itemsThisWeek, lastWeek: itemsLastWeek, scaleMax: itemsScaleMax,
        clockwiseOnScreen: false, angleFn: lowerAngle, color: itemsColor, hoursElapsed: hoursElapsed, cardBgColor: cardBgColor, glowBlur: glowBlur, isDark: isDark)
}

private func upperAngle(value: Double, max: Double) -> Double {
    135.0 + clamp01(value / max) * 270.0
}

private func lowerAngle(value: Double, max: Double) -> Double {
    135.0 - clamp01(value / max) * 90.0
}

private func clamp01(_ x: Double) -> Double {
    guard x.isFinite else { return 0 }
    return Swift.max(0, Swift.min(1, x))
}

private func drawRecallBar(ctx: GraphicsContext, sc: Double, recall: Double?, barColor: Color, isDark: Bool) {
    let barW = 60.0, barH = 5.0, barX = svgCX - barW / 2, barY = 7.0
    let trackRect = CGRect(x: barX * sc, y: barY * sc, width: barW * sc, height: barH * sc)
    let trackOpacity: Double = isDark ? 0.12 : 0.18
    let trackBaseColor: Color = isDark ? .white : .black
    ctx.fill(Path(roundedRect: trackRect, cornerRadius: 2.5 * sc), with: .color(trackBaseColor.opacity(trackOpacity)))
    if let r = recall, r > 0 {
        let filled = r * barW
        let filledRect = CGRect(x: barX * sc, y: barY * sc, width: filled * sc, height: barH * sc)
        let fillOpacity: Double = isDark ? 0.85 : 0.75
        ctx.fill(Path(roundedRect: filledRect, cornerRadius: 2.5 * sc), with: .color(barColor.opacity(fillOpacity)))
    }
}

private func drawSubGauge(
    ctx: GraphicsContext, sc: Double, cx: Double, cy: Double, rTrack: Double, rNeedle: Double, rPaceNeedle: Double,
    curValue: Double, lastWeek: Double, scaleMax: Double, clockwiseOnScreen: Bool,
    angleFn: (Double, Double) -> Double, color: Color, hoursElapsed: Double, cardBgColor: Color, glowBlur: Double, isDark: Bool
) {
    let effectiveMax = max(scaleMax, curValue)
    let onPace = (lastWeek / 168.0) * hoursElapsed
    let curAngle = angleFn(curValue, effectiveMax)
    let paceAngle = angleFn(onPace, effectiveMax)
    let pathCW = !clockwiseOnScreen
    let trackStartDeg = 135.0, trackEndDeg = 45.0

    let trackOpacity: Double = isDark ? 0.12 : 0.18
    let trackBaseColor: Color = isDark ? .white : .black
    ctx.stroke(arcPath(sc: sc, cx: cx, cy: cy, r: rTrack, startDeg: trackStartDeg, endDeg: trackEndDeg, pathCW: pathCW),
        with: .color(trackBaseColor.opacity(trackOpacity)), style: StrokeStyle(lineWidth: 3 * sc, lineCap: .round))

    let tickFracs: [Double] = clockwiseOnScreen ? [0, 0.25, 0.5, 0.75, 1.0] : [0, 0.5, 1.0]
    let tickOpacity: Double = isDark ? 0.25 : 0.45
    var shownTickLabels = Set<Int>()
    for frac in tickFracs {
        let ta = clockwiseOnScreen ? 135.0 + frac * 270.0 : 135.0 - frac * 90.0
        let inner = svgPt(sc: sc, cx: cx, cy: cy, r: rTrack + 4, deg: ta)
        let outer = svgPt(sc: sc, cx: cx, cy: cy, r: rTrack + 9, deg: ta)
        var tick = Path()
        tick.move(to: inner)
        tick.addLine(to: outer)
        let lw = (frac == 0 || frac == 1) ? 1.5 * sc : 1.0 * sc
        ctx.stroke(tick, with: .color(color.opacity(tickOpacity)), style: StrokeStyle(lineWidth: lw, lineCap: .round))

        if frac > 0, effectiveMax > 0 {
            let tickValue = Int((frac * effectiveMax).rounded())
            if tickValue > 0, !shownTickLabels.contains(tickValue), tickValue > 1 || frac == 1.0 {
                shownTickLabels.insert(tickValue)
                let labelPt = svgPt(sc: sc, cx: cx, cy: cy, r: rTrack + 16, deg: ta)
                let text = Text(String(tickValue))
                    .font(.system(size: 9 * sc, weight: .semibold, design: .default))
                    .foregroundColor(color.opacity(isDark ? 0.65 : 0.85))
                ctx.draw(text, at: labelPt, anchor: .center)
            }
        }
    }

    let redColor = Color(red: 1, green: 0.13, blue: 0.13)
    if curValue > scaleMax {
        let oldMaxAngle = angleFn(scaleMax, effectiveMax)
        let ws = svgPt(sc: sc, cx: cx, cy: cy, r: rNeedle, deg: oldMaxAngle)
        let hubPt = CGPoint(x: cx * sc, y: cy * sc)
        var wedge = Path()
        wedge.move(to: hubPt)
        wedge.addLine(to: ws)
        wedge.addArc(center: hubPt, radius: rNeedle * sc, startAngle: .degrees(oldMaxAngle), endAngle: .degrees(curAngle), clockwise: pathCW)
        wedge.addLine(to: hubPt)
        let redOpacity: Double = isDark ? 0.22 : 0.15
        ctx.fill(wedge, with: .color(redColor.opacity(redOpacity)))
        var rl = Path()
        rl.move(to: hubPt)
        rl.addLine(to: ws)
        var glowCtx = ctx
        glowCtx.addFilter(.blur(radius: 2.5 * sc))
        glowCtx.stroke(rl, with: .color(redColor), style: StrokeStyle(lineWidth: 2 * sc, lineCap: .round))
        ctx.stroke(rl, with: .color(redColor), style: StrokeStyle(lineWidth: 2 * sc, lineCap: .round))
    }

    let progressOpacity: Double = isDark ? 0.35 : 0.5
    if curValue > 0 {
        ctx.stroke(arcPath(sc: sc, cx: cx, cy: cy, r: rTrack, startDeg: trackStartDeg, endDeg: curAngle, pathCW: pathCW),
            with: .color(color.opacity(progressOpacity)), style: StrokeStyle(lineWidth: 3 * sc, lineCap: .round))
    }

    let rDelta = clockwiseOnScreen ? rTrack - 14 : rTrack - 14
    let arcFrom = clockwiseOnScreen ? Swift.min(paceAngle, curAngle) : Swift.max(paceAngle, curAngle)
    let arcTo = clockwiseOnScreen ? Swift.max(paceAngle, curAngle) : Swift.min(paceAngle, curAngle)
    let deltaSpan = clockwiseOnScreen ? arcTo - arcFrom : arcFrom - arcTo
    let hubPt = CGPoint(x: cx * sc, y: cy * sc)
    if deltaSpan > 0.5 {
        let deltaPath = arcPath(sc: sc, cx: cx, cy: cy, r: rDelta, startDeg: arcFrom, endDeg: arcTo, pathCW: pathCW)
        let deltaOpacity: Double = isDark ? 0.55 : 0.65
        var glowCtx = ctx
        glowCtx.addFilter(.blur(radius: glowBlur * sc))
        glowCtx.stroke(deltaPath, with: .color(color.opacity(deltaOpacity)), style: StrokeStyle(lineWidth: 2.5 * sc, lineCap: .round))
        ctx.stroke(deltaPath, with: .color(color.opacity(deltaOpacity)), style: StrokeStyle(lineWidth: 2.5 * sc, lineCap: .round))
        let nub = svgPt(sc: sc, cx: cx, cy: cy, r: rDelta, deg: curAngle)
        let nubR = 2.5 * sc
        let nubOpacity: Double = isDark ? 0.8 : 0.7
        ctx.fill(Path(ellipseIn: CGRect(x: nub.x - nubR, y: nub.y - nubR, width: nubR * 2, height: nubR * 2)),
            with: .color(color.opacity(nubOpacity)))
    }

    let paceTip = svgPt(sc: sc, cx: cx, cy: cy, r: rPaceNeedle, deg: paceAngle)
    var pacePath = Path()
    pacePath.move(to: hubPt)
    pacePath.addLine(to: paceTip)
    let paceOpacity: Double = isDark ? 0.40 : 0.55
    ctx.stroke(pacePath, with: .color(color.opacity(paceOpacity)), style: StrokeStyle(lineWidth: 1.5 * sc, lineCap: .round, dash: [4 * sc, 3 * sc]))

    let curTip = svgPt(sc: sc, cx: cx, cy: cy, r: rNeedle, deg: curAngle)
    var needlePath = Path()
    needlePath.move(to: hubPt)
    needlePath.addLine(to: curTip)
    let needleStyle = StrokeStyle(lineWidth: 3 * sc, lineCap: .round)
    var glowCtx = ctx
    glowCtx.addFilter(.blur(radius: glowBlur * sc))
    glowCtx.stroke(needlePath, with: .color(color), style: needleStyle)
    ctx.stroke(needlePath, with: .color(color), style: needleStyle)

    let hr = hubRadius * sc
    ctx.fill(Path(ellipseIn: CGRect(x: hubPt.x - hr, y: hubPt.y - hr, width: hr * 2, height: hr * 2)), with: .color(color))
    let ir = (hubRadius - 2.5) * sc
    ctx.fill(Path(ellipseIn: CGRect(x: hubPt.x - ir, y: hubPt.y - ir, width: ir * 2, height: ir * 2)), with: .color(cardBgColor))
}

private func svgPt(sc: Double, cx: Double, cy: Double, r: Double, deg: Double) -> CGPoint {
    let rad = deg * .pi / 180
    return CGPoint(x: (cx + r * cos(rad)) * sc, y: (cy + r * sin(rad)) * sc)
}

private func arcPath(sc: Double, cx: Double, cy: Double, r: Double, startDeg: Double, endDeg: Double, pathCW: Bool) -> Path {
    Path { p in
        p.addArc(center: CGPoint(x: cx * sc, y: cy * sc), radius: r * sc,
            startAngle: .degrees(startDeg), endAngle: .degrees(endDeg), clockwise: pathCW)
    }
}
