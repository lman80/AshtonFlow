import Cocoa

/// Sends the system Play/Pause media key so background media (Music, Spotify,
/// Safari/YouTube, QuickTime, podcasts, …) pauses while you dictate and resumes
/// after. This is the one control that reaches every media app uniformly, and —
/// unlike muting — it actually stops playback, so AirPods/Bluetooth headphones
/// don't drop to call-quality audio in the background.
enum MediaController {
    private static let playPauseKey: Int32 = 16 // NX_KEYTYPE_PLAY

    /// Toggle play/pause across whatever is the current media app.
    static func sendPlayPause() {
        postKey(down: true)
        postKey(down: false)
    }

    private static func postKey(down: Bool) {
        let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xA00)
                                                 : NSEvent.ModifierFlags(rawValue: 0xB00)
        let data1 = (Int(playPauseKey) << 16) | ((down ? 0xA : 0xB) << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
