struct SplitMenuBarReadout: Equatable, Sendable {
    let upper: String
    let lower: String

    static func make(
        enabled: Bool, isLoggedIn: Bool, hasUsageData: Bool,
        suppressesLegacyMeter: Bool, presentation: SplitUsagePresentation?
    ) -> Self? {
        guard enabled, isLoggedIn, hasUsageData, suppressesLegacyMeter else { return nil }
        guard let presentation else { return Self(upper: "—", lower: "—") }
        return Self(upper: presentation.pools[0].percentText, lower: presentation.pools[1].percentText)
    }
}
