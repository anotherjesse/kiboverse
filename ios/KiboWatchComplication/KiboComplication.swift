import SwiftUI
import WidgetKit

private struct KiboComplicationEntry: TimelineEntry {
    let date: Date
}

private struct KiboComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> KiboComplicationEntry {
        KiboComplicationEntry(date: .now)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (KiboComplicationEntry) -> Void
    ) {
        completion(KiboComplicationEntry(date: .now))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<KiboComplicationEntry>) -> Void
    ) {
        completion(Timeline(entries: [KiboComplicationEntry(date: .now)], policy: .never))
    }
}

private struct KiboComplicationView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            Image(systemName: "waveform")
                .font(.system(size: 19, weight: .semibold))
                // kiboCoral, inlined: this extension target does not compile
                // Shared/Theme.swift.
                .foregroundStyle(Color(red: 0.94, green: 0.34, blue: 0.29))
                .widgetAccentable()
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel("Open Kibo")
    }
}

private struct KiboComplication: Widget {
    let kind = "KiboComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KiboComplicationProvider()) { _ in
            KiboComplicationView()
                .widgetURL(URL(string: "kibo-watch://talk"))
        }
        .configurationDisplayName("Kibo")
        .description("Open Kibo from your watch face.")
        .supportedFamilies([.accessoryCircular])
    }
}

@main
struct KiboComplicationBundle: WidgetBundle {
    var body: some Widget {
        KiboComplication()
    }
}

#Preview(as: .accessoryCircular) {
    KiboComplication()
} timeline: {
    KiboComplicationEntry(date: .now)
}
