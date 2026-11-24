// FineTuneTests/HUDDisplaySettingTests.swift

import Testing
import Foundation
@testable import FineTune

@Suite("HUD display setting")
struct HUDDisplaySettingTests {

    @Test("The HUD shows on the active display by default, also with settings saved before the option")
    func defaultsToActive() throws {
        #expect(AppSettings().hudDisplay == .active)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded.hudDisplay == .active)
    }

    @Test("The choice survives a save")
    func roundTrips() throws {
        var settings = AppSettings()
        settings.hudDisplay = .main
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.hudDisplay == .main)
    }
}
