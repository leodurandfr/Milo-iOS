import CoreText
import Foundation

enum FontRegistration {
    static let registerFonts: Void = {
        guard let fontURL = Bundle.main.url(forResource: "SpaceMono-Regular", withExtension: "ttf") else {
            return
        }
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }()
}
