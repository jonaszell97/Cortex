import Testing
@testable import Cortex

@MainActor
@Suite struct SpeakerBoostTests {
    /// Speakers that remember what they were set to.
    @MainActor final class Speakers {
        var level: SpeakerLevel?
        var writes: [SpeakerLevel] = []
        init(_ level: SpeakerLevel?) { self.level = level }
        lazy var boost = SpeakerBoost(read: { self.level }, write: { self.level = $0; self.writes.append($0) })
    }

    let off = SpeakerLevel(isMuted: true, volume: 0.2)

    @Test func whatMakesASoundAudible() {
        #expect(SpeakerLevel(isMuted: true, volume: 0.2).audible == SpeakerLevel(isMuted: false, volume: 0.5))
        #expect(SpeakerLevel(isMuted: true, volume: 0.8).audible == SpeakerLevel(isMuted: false, volume: 0.8), "not turned down")
        #expect(SpeakerLevel(isMuted: false, volume: 0).audible == SpeakerLevel(isMuted: false, volume: 0.5))
        #expect(SpeakerLevel(isMuted: false, volume: 0.1).audible == nil, "quiet is not off")
    }

    @Test func turnsOnForTheSoundAndBackOff() {
        let speakers = Speakers(off)
        speakers.boost.begin()
        #expect(speakers.level == SpeakerLevel(isMuted: false, volume: 0.5))
        speakers.boost.end()
        #expect(speakers.level == off)
    }

    @Test func leavesAudibleSpeakersAlone() {
        let speakers = Speakers(SpeakerLevel(isMuted: false, volume: 0.3))
        speakers.boost.begin()
        speakers.boost.end()
        #expect(speakers.writes.isEmpty)
    }

    @Test func leavesOtherOutputsAlone() {
        let speakers = Speakers(nil)
        speakers.boost.begin()
        speakers.boost.end()
        #expect(speakers.writes.isEmpty)
    }

    @Test func overlappingSoundsRestoreAtTheEnd() {
        let speakers = Speakers(off)
        speakers.boost.begin()
        speakers.boost.begin()
        speakers.boost.end()
        #expect(speakers.level?.isMuted == false, "one is still playing")
        speakers.boost.end()
        #expect(speakers.level == off)
    }

    @Test func restoresDespiteTheDeviceRoundingTheVolume() {
        let speakers = Speakers(off)
        speakers.boost.begin()
        speakers.level?.volume = 0.49999997
        speakers.boost.end()
        #expect(speakers.level == off)
    }

    @Test func keepsWhatYouChangedMeanwhile() {
        let speakers = Speakers(off)
        speakers.boost.begin()
        let chosen = SpeakerLevel(isMuted: false, volume: 0.9)
        speakers.level = chosen
        speakers.boost.end()
        #expect(speakers.level == chosen)
    }
}
