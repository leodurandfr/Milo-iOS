import WidgetKit
import SwiftUI

struct MiloWidget: Widget {
    let kind = "MiloWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MiloTimelineProvider()) { entry in
            MiloWidgetView(entry: entry)
        }
        .configurationDisplayName("Milo")
        .description("Contrôlez le volume de Milo.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
        .pushHandler(MiloWidgetPushHandler.self)
    }
}
