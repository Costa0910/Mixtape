import WidgetKit
import SwiftUI

struct SnagEntry: TimelineEntry { let date: Date }

struct SnagProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnagEntry { SnagEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (SnagEntry) -> Void) {
        completion(SnagEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnagEntry>) -> Void) {
        completion(Timeline(entries: [SnagEntry(date: .now)], policy: .never))
    }
}

struct SnagWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemSmall {
                small
            } else {
                medium
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [.indigo, .purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    // Small: whole tile plays the Smart Mix.
    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "sparkles").font(.title2)
            Spacer()
            Text("Smart Mix").font(.headline).bold()
            Text("Tap to play").font(.caption2).opacity(0.85)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "snag://smartmix"))
    }

    // Medium: two tappable actions.
    private var medium: some View {
        HStack(spacing: 12) {
            Link(destination: URL(string: "snag://smartmix")!) {
                tile(icon: "sparkles", title: "Smart Mix", subtitle: "Tuned to you")
            }
            Link(destination: URL(string: "snag://shuffle")!) {
                tile(icon: "shuffle", title: "Shuffle", subtitle: "Whole library")
            }
        }
        .foregroundStyle(.white)
    }

    private func tile(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.title3)
            Spacer()
            Text(title).font(.subheadline.bold())
            Text(subtitle).font(.caption2).opacity(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SnagWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SnagWidget", provider: SnagProvider()) { _ in
            SnagWidgetView()
        }
        .configurationDisplayName("Snag")
        .description("Play your Smart Mix or shuffle your library.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SnagWidgetBundle: WidgetBundle {
    var body: some Widget { SnagWidget() }
}
