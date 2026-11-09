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
}
