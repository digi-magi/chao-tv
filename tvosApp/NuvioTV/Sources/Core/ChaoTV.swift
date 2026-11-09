import Foundation

/// House build switches for Chao TV (fork of NuvioTVOS, GPL-3.0).
/// One shared household setup: no accounts, no profile picker, no Watch Party
/// or Calendar, and a top tab bar instead of the sidebar.
enum ChaoTV {
    static let displayName = "Chao TV"
    /// Everyone shares one profile; the who's-watching picker auto-enters it.
    static let sharedProfileOnly = true
    /// No Nuvio account sign-in screen on launch.
    static let skipsLoginGate = true
    static let showsCalendar = false
    /// Settings > Integrations shows only Add-ons: no Simkl / MDBList / WeTrakr /
    /// Trakt / AI subtitles / metadata providers / Debrid / P2P / SMB / Usenet /
    /// Jellyfin. Streams come from the house cache add-on (Real-Debrid upstream).
    static let showsThirdPartyIntegrations = false
    /// Settings > Account & Profiles is gone: no accounts, one shared profile.
    static let showsAccountSettings = false
    /// The in-app BitTorrent engine never runs: nothing P2P from the TV.
    static let allowsP2P = false

    /// Household defaults applied once (only where the user never chose):
    /// Auto Select Stream on, so resume / agent "play" start immediately
    /// instead of opening the source picker.
    static func applyHouseDefaults(profileId: String?) {
        for store in [ProfileSettings.store(for: profileId), ProfileSettings.current] {
            if store.object(forKey: SettingsKey.smartStreamSelection) == nil {
                store.set(true, forKey: SettingsKey.smartStreamSelection)
            }
        }
    }
}
