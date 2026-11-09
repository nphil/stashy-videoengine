import Testing
@testable import VideoEngine

/// Pacing against a model of AVPlayer on the remux's live playlist: it reloads the playlist every half
/// target duration, loads listed segments at four times real time up to 60 s ahead, and stops loading once
/// the playlist has gone 1.5 target durations without changing, until it changes again (field log,
/// 2026-11-08: it played the 57 s it had and waited at 774.5 s while later segments were listed).
struct PaceGateTests {
    private struct Player {
        static let target: Double = 10
        var playhead = 0.0
        /// End of the buffered media from the playhead on.
        var loaded = 0.0
        /// End of the segments in the player's copy of the playlist, and when that copy last changed.
        var listed = 0.0
        var changed = 0.0
        var nextReload = 0.0
        var playing = true

        var waiting: Bool { playing && loaded - playhead < 0.05 }

        mutating func step(now: Double, dt: Double, served: Double) {
            if now >= nextReload {
                if served != listed {
                    listed = served
                    changed = now
                }
                nextReload = now + Self.target / 2
            }
            if now - changed <= 1.5 * Self.target, loaded < listed {
                loaded = min(listed, loaded + 4 * dt, playhead + 60)
            }
            if playing { playhead = min(loaded, playhead + dt) }
        }

        mutating func seek(to time: Double) {
            playhead = time
            loaded = time
        }
    }

    /// The remux reading at eight times real time while allowed; a segment is listed once the keyframe
    /// after it, 4 s on, is read.
    private struct Simulation {
        var allows: (_ produced: Double, _ playhead: Double, _ waiting: Bool) -> Bool
        var reportsWaiting: Bool
        var player = Player()
        var produced = 0.0
        var now = 0.0
        /// Longest time the player has waited for data since `resetWaits()`.
        var longestWait = 0.0
        private var waitingSince: Double?

        init(reportsWaiting: Bool, allows: @escaping (Double, Double, Bool) -> Bool) {
            self.reportsWaiting = reportsWaiting
            self.allows = allows
        }

        var served: Double { (produced / 4).rounded(.down) * 4 }

        mutating func run(for seconds: Double) {
            let dt = 0.1
            for _ in 0..<Int((seconds / dt).rounded()) {
                if allows(produced, player.playhead, reportsWaiting && player.waiting) { produced += 8 * dt }
                player.step(now: now, dt: dt, served: served)
                now += dt
                if player.waiting {
                    let since = waitingSince ?? now
                    waitingSince = since
                    longestWait = max(longestWait, now - since)
                } else {
                    waitingSince = nil
                }
            }
        }

        mutating func resetWaits() {
            longestWait = 0
            waitingSince = nil
        }
    }

    private static func gated() -> (Double, Double, Bool) -> Bool {
        var gate = PaceGate(lead: 75, headroom: Player.target)
        return { gate.allows(produced: $0, playhead: $1, playerWaiting: $2) }
    }

    /// The field case, with only the playhead reported, as Stashy does.
    @Test func backwardSeekWithinTheRunKeepsPlaying() {
        var paced = Simulation(reportsWaiting: false, allows: Self.gated())
        paced.run(for: 300)
        let target = paced.player.playhead - 100
        paced.player.seek(to: target)
        paced.resetWaits()
        paced.run(for: 600)
        print("pace: after a 100 s backward seek, longest wait \(paced.longestWait) s, played \(paced.player.playhead - target) s of 600")
        #expect(paced.longestWait < 2)
        #expect(paced.player.playhead - target > 595)

        // The rule it replaces: wait while more than the lead ahead of the playhead.
        var old = Simulation(reportsWaiting: false) { produced, playhead, _ in produced - playhead <= 75 }
        old.run(for: 300)
        old.player.seek(to: old.player.playhead - 100)
        old.resetWaits()
        old.run(for: 600)
        #expect(old.longestWait > 500)
    }

    /// Paused in the background, where the buffer may be dropped, then resumed.
    @Test func resumeAfterALongPauseWithTheBufferDroppedPlaysOn() {
        var sim = Simulation(reportsWaiting: true, allows: Self.gated())
        sim.run(for: 200)
        sim.player.playing = false
        sim.run(for: 600)
        print("pace: paused 600 s, produced \(sim.produced - sim.player.playhead) s ahead")
        #expect(sim.produced - sim.player.playhead <= 75 + Player.target + 1)
        sim.player.loaded = sim.player.playhead
        sim.player.playing = true
        let resumedAt = sim.player.playhead
        sim.resetWaits()
        sim.run(for: 120)
        print("pace: resumed with no buffer, longest wait \(sim.longestWait) s")
        #expect(sim.longestWait < 6)
        #expect(sim.player.playhead - resumedAt > 110)
    }

    @Test func leadDoublesOverAFarOrNarrowLink() {
        #expect(PaceGate.lead(base: 75, latency: 0.01, bytesPerSecond: 10e6, mediaBytesPerSecond: 1.4e6) == 75)
        #expect(PaceGate.lead(base: 75, latency: 0.12, bytesPerSecond: 10e6, mediaBytesPerSecond: 1.4e6) == 150)
        #expect(PaceGate.lead(base: 75, latency: 0.01, bytesPerSecond: 2e6, mediaBytesPerSecond: 1.4e6) == 150)
    }
}
