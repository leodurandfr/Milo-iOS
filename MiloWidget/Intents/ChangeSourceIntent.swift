import AppIntents
import WidgetKit

struct ChangeSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Changer la source"
    static var description: IntentDescription = "Change la source audio de Milo"

    @Parameter(title: "Source")
    var sourceName: String

    init() {}

    init(sourceName: String) {
        self.sourceName = sourceName
    }

    func perform() async throws -> some IntentResult {
        try await MiloAPIClient.changeSource(sourceName)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
