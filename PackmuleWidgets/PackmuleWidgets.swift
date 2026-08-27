//
//  PackmuleWidgets.swift
//  PackmuleWidgets
//
//  The Dynamic Island and lock screen Live Activity: a pack mule walking the
//  trail, position = bytes hauled. Oregon Trail energy, one step per update.
//

import WidgetKit
import SwiftUI
import ActivityKit

@main
struct PackmuleWidgets: WidgetBundle {
    var body: some Widget {
        TransferLiveActivity()
    }
}

/// Fixed palette (the extension has no theme environment): the Mule theme's
/// leather tan on the island's black.
enum PMColors {
    static let mule = Color(red: 0.788, green: 0.482, blue: 0.290)
    static let pack = Color(red: 0.55, green: 0.36, blue: 0.22)
    static let track = Color.white.opacity(0.28)
    static let dim = Color.white.opacity(0.6)
}

struct TransferLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferAttributes.self) { context in
            LockScreenTransferView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("\(Int(context.state.fraction * 100))%")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(PMColors.mule)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: context.state.direction == "up"
                              ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(PMColors.mule)
                        if context.state.queued > 0 {
                            Text("+\(context.state.queued) waiting")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(PMColors.dim)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
                        MuleTrailView(fraction: context.state.fraction,
                                      finished: context.state.finished)
                            .frame(height: 30)
                        HStack {
                            Text(context.state.itemName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(context.state.detailText)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(PMColors.dim)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            } compactLeading: {
                MuleGlyph(fraction: context.state.fraction)
                    .frame(width: 21, height: 14)
            } compactTrailing: {
                Text("\(Int(context.state.fraction * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(PMColors.mule)
            } minimal: {
                MuleGlyph()
                    .frame(width: 19, height: 13)
            }
        }
    }
}

// MARK: - Pieces

/// The 16-bit pack mule. He takes a step each time the percent ticks.
struct MuleGlyph: View {
    var fraction: Double = 0
    var body: some View {
        PixelSprite(map: MuleSprites.stepFrame(for: fraction),
                    palette: MuleSprites.palette)
    }
}

/// The dashed trail with the mule at `fraction` of the way along. Updates
/// arrive about once a second, so he steps rather than glides. As intended.
struct MuleTrailView: View {
    let fraction: Double
    let finished: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let muleHeight = height - 5
            let muleWidth = muleHeight * 26 / 18
            let travel = max(0, width - muleWidth)
            let x = travel * CGFloat(min(1, max(0, fraction)))
            ZStack(alignment: .topLeading) {
                // the trail ahead
                Path { p in
                    p.move(to: CGPoint(x: 0, y: height - 2))
                    p.addLine(to: CGPoint(x: width, y: height - 2))
                }
                .stroke(PMColors.track, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 6]))
                // the ground already covered
                Path { p in
                    p.move(to: CGPoint(x: 0, y: height - 2))
                    p.addLine(to: CGPoint(x: max(2, x + muleWidth * 0.55), y: height - 2))
                }
                .stroke(PMColors.mule.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                MuleGlyph(fraction: fraction)
                    .frame(width: muleWidth, height: muleHeight)
                    .offset(x: x, y: 0)
                if finished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(PMColors.mule)
                        .offset(x: width - 14, y: -2)
                }
            }
        }
    }
}

struct LockScreenTransferView: View {
    let state: TransferAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.finished ? "PACKMULE · DELIVERED" : "PACKMULE · HAULING")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(PMColors.dim)
                Spacer()
                if state.queued > 0 {
                    Text("+\(state.queued) waiting")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(PMColors.dim)
                }
            }
            MuleTrailView(fraction: state.fraction, finished: state.finished)
                .frame(height: 34)
            HStack {
                Text(state.itemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(Int(state.fraction * 100))% · \(state.detailText)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(PMColors.dim)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .activityBackgroundTint(Color(red: 0.08, green: 0.063, blue: 0.043))
        .activitySystemActionForegroundColor(PMColors.mule)
    }
}
