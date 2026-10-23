//
//  AirShareLiveActivity.swift
//  Lock-screen banner + Dynamic Island for AirShare downloads, signing and installs.
//  App icon inside a transparent progress ring, percentage on the right, your accent color.
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AirShareLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.1, *) { AirShareLiveActivityWidget() }
    }
}

@available(iOS 16.1, *)
struct AirShareLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AirShareActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IconRing(state: s, side: 40)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(percent(s))%").font(.title3.weight(.bold)).foregroundColor(stateColor(s)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Bar(state: s)
                        Text(s.detail).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                IconRing(state: s, side: 22)
            } compactTrailing: {
                Text("\(percent(s))%").font(.caption2.weight(.bold)).foregroundColor(stateColor(s)).monospacedDigit()
            } minimal: {
                IconRing(state: s, side: 22)
            }
        }
    }
}

private func percent(_ s: AirShareActivityAttributes.ContentState) -> Int { Int((min(max(s.progress, 0), 1) * 100).rounded()) }

private func accent(_ s: AirShareActivityAttributes.ContentState) -> Color { Color(airHex: s.accentHex) }

@available(iOS 16.1, *)
private func stateColor(_ s: AirShareActivityAttributes.ContentState) -> Color {
    s.failed ? .orange : (s.finished ? .green : accent(s))
}

extension Color {
    init(airHex: String) {
        var h = airHex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        guard h.count == 6, Scanner(string: h).scanHexInt64(&v) else { self = Color(red: 1, green: 0.6, blue: 0.1); return }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// App icon wrapped in a transparent ring that fills as the work progresses.
@available(iOS 16.1, *)
private struct IconRing: View {
    let state: AirShareActivityAttributes.ContentState
    let side: CGFloat
    var body: some View {
        ZStack {
            Group {
                if let d = state.iconData, let ui = UIImage(data: d) {
                    Image(uiImage: ui).resizable().scaledToFill()           // the app being installed
                } else {
                    Image("aircore_logo").resizable().scaledToFit().padding(side * 0.12).background(Color.black)
                }
            }
            .frame(width: side * 0.8, height: side * 0.8)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
            Circle().stroke(Color.clear, lineWidth: max(2, side * 0.07))
            Circle().trim(from: 0, to: max(0.03, min(state.progress, 1)))
                .stroke(stateColor(state), style: StrokeStyle(lineWidth: max(2, side * 0.07), lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: side, height: side)
    }
}

@available(iOS 16.1, *)
private struct Bar: View {
    let state: AirShareActivityAttributes.ContentState
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(stateColor(state)).frame(width: max(6, g.size.width * min(max(state.progress, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

@available(iOS 16.1, *)
private struct LockScreenView: View {
    let state: AirShareActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 14) {
            IconRing(state: state, side: 48)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(percent(state))%").font(.system(size: 17, weight: .bold)).foregroundColor(stateColor(state)).monospacedDigit()
                }
                Bar(state: state)
                Text(state.detail).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(16)
    }
}
