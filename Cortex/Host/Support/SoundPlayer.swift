import AVFoundation

/// Plays `$sound`'s files (`ActionOutput.play`). Each sound gets its own
/// player, kept until it ends, so sounds started one after another overlap.
/// Muted built-in speakers are turned on while a sound plays.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private var playing: [ObjectIdentifier: (player: AVPlayer, observers: [any NSObjectProtocol], status: NSKeyValueObservation)] = [:]

    func play(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let id = ObjectIdentifier(player)
        // Ending or failing, the player is let go.
        let observers = [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(id) }
            }
        }
        // A file that cannot be opened posts neither.
        let status = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(id) } }
        }
        playing[id] = (player, observers, status)
        SpeakerBoost.shared.begin()
        player.play()
    }

    private func finish(_ id: ObjectIdentifier) {
        guard let entry = playing.removeValue(forKey: id) else { return }
        entry.observers.forEach(NotificationCenter.default.removeObserver)
        SpeakerBoost.shared.end()
    }
}
