import SwiftUI
import WidgetKit

struct MiloWidgetView: View {
    var entry: MiloWidgetEntry
    @Environment(\.colorScheme) private var colorScheme

    private var buttonBg: Color {
        colorScheme == .dark
            ? Color(red: 0x2C/255, green: 0x2C/255, blue: 0x2E/255)
            : Color(red: 0xF7/255, green: 0xF7/255, blue: 0xF7/255)
    }

    private var textColor: Color {
        Color(red: 0xA6/255, green: 0xAC/255, blue: 0xA6/255)
    }

    private var bgColor: Color {
        colorScheme == .dark
            ? Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1E/255)
            : .white
    }

    init(entry: MiloWidgetEntry) {
        self.entry = entry
        _ = FontRegistration.registerFonts
    }

    var body: some View {
        if !entry.data.isConnected {
            disconnectedView
        } else {
            connectedView
        }
    }

    // MARK: - Connected View

    private var connectedView: some View {
        VStack(spacing: 12) {
            // Logo ou volume — centré dans l'espace restant
            Group {
                if entry.showVolume {
                    Text(volumeText)
                        .font(.custom("SpaceMono-Regular", size: 18))
                        .foregroundStyle(textColor)
                        .id("volume")
                } else {
                    Image("Logo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 26)
                        .foregroundStyle(textColor)
                        .id("logo")
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: entry.showVolume)
            .frame(maxWidth: .infinity)

            // Boutons volume
            HStack(spacing: 8) {
                Button(intent: DecreaseVolumeIntent()) {
                    Image("MinusIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundStyle(textColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(buttonBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button(intent: IncreaseVolumeIntent()) {
                    Image("PlusIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundStyle(textColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(buttonBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgColor)
    }

    // MARK: - Disconnected View

    private var disconnectedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Milo indisponible")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bgColor)
    }

    // MARK: - Helpers

    private var volumeText: String {
        let db = entry.data.volumeDB
        let defaults = UserDefaults(suiteName: MiloAPIClient.appGroupID)
        let limitMin = defaults?.double(forKey: "volume_limit_min_db") ?? -80
        if db <= limitMin { return String(localized: "muted") }
        return "\(Int(db)) dB"
    }
}
