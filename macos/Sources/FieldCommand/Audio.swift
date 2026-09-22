import AVFoundation
import Foundation

/// Procedurally synthesised sound effects — the same thirteen recipes as the Linux edition's audio.py, so both
/// platforms sound alike and no audio files are shipped. Buffers are made once, then played from a small pool
/// of player nodes; rapid repeats of the same effect are throttled by `minGap`, as in the Python edition.
enum Audio {
    static let rate = 22050.0
    static let names = ["rifle", "cannon", "explosion", "turret", "complete", "alert", "wave", "snipe", "siege",
                        "pop", "click", "victory", "defeat"]
    /// How soon the same effect may play again, in seconds — gunfire otherwise stacks into a wall.
    static let minGaps: [String: Double] = ["rifle": 0.05, "cannon": 0.08, "turret": 0.06, "explosion": 0.08, "snipe": 0.05]

    private static var engine: AVAudioEngine?
    private static var players: [AVAudioPlayerNode] = []
    private static var buffers: [String: AVAudioPCMBuffer] = [:]
    private static var lastPlayed: [String: Double] = [:]
    private static var next = 0
    private static var attempted = false
    private(set) static var ready = false

    // MARK: Synthesis

    private struct Noise {
        var state: UInt64
        mutating func next() -> Float {          // xorshift64*, mapped to [-1, 1)
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let v = state &* 2685821657736338717
            return Float(Double(v >> 11) / Double(1 << 53)) * 2 - 1
        }
    }

    private static func n(_ seconds: Double) -> Int { Int(rate * seconds) }

    private static func env(_ count: Int, attack: Double = 0.005, decay: Double? = nil) -> [Float] {
        (0..<count).map { i in
            let t = Double(i) / rate
            let a = min(1, t / max(attack, 1e-4))
            let d = decay.map { exp(-t / $0) } ?? 1
            return Float(a * d)
        }
    }

    private static func noise(_ count: Int, _ rng: inout Noise) -> [Float] { (0..<count).map { _ in rng.next() } }

    private static func tone(_ freq: Double, _ count: Int, square: Bool = false) -> [Float] {
        (0..<count).map { i in
            let s = sin(2 * .pi * freq * Double(i) / rate)
            return Float(square ? (s > 0 ? 1 : (s < 0 ? -1 : 0)) : s)
        }
    }

    private static func lowpass(_ x: [Float], _ k: Float) -> [Float] {
        var acc: Float = 0
        return x.map { v in acc += k * (v - acc); return acc }
    }

    private static func mul(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 * $1 } }
    private static func gain(_ a: [Float], _ g: Float) -> [Float] { a.map { $0 * g } }
    private static func add(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }

    /// Every effect as samples in [-1, 1], already scaled by its volume.
    static func synthesise() -> [String: [Float]] {
        var rng = Noise(state: 0x9E3779B97F4A7C15)
        var out: [String: [Float]] = [:]
        func make(_ name: String, _ samples: [Float], _ volume: Float) { out[name] = samples.map { max(-1, min(1, $0 * volume)) } }
        make("rifle", mul(noise(n(0.08), &rng), env(n(0.08), decay: 0.018)), 0.18)
        make("cannon", gain(mul(lowpass(noise(n(0.5), &rng), 0.08), env(n(0.5), decay: 0.12)), 2.5), 0.5)
        make("explosion", gain(mul(lowpass(noise(n(0.9), &rng), 0.05), env(n(0.9), decay: 0.25)), 3), 0.6)
        make("turret", mul(noise(n(0.1), &rng), env(n(0.1), decay: 0.025)), 0.2)
        make("complete", mul(tone(880, n(0.12)), env(n(0.12), decay: 0.08)) + mul(tone(1320, n(0.25)), env(n(0.25), decay: 0.12)), 0.25)
        let alert = gain(tone(440, n(0.15), square: true), 0.5) + [Float](repeating: 0, count: n(0.05)) + gain(tone(330, n(0.25), square: true), 0.5)
        make("alert", mul(alert, env(alert.count, decay: 0.4)), 0.18)
        let wave = gain(tone(220, n(0.3), square: true) + tone(196, n(0.45), square: true), 0.4)
        make("wave", mul(wave, env(wave.count, decay: 0.6)), 0.2)
        let crack = mul(lowpass(noise(n(0.35), &rng), 0.55), env(n(0.35), attack: 0.001, decay: 0.05))
        let tail = gain(mul(lowpass(noise(n(0.35), &rng), 0.06), env(n(0.35), attack: 0.02, decay: 0.16)), 0.5)
        make("snipe", add(gain(crack, 1.6), tail), 0.42)
        let hiss = gain(mul(lowpass(noise(n(0.5), &rng), 0.25), env(n(0.5), attack: 0.05, decay: 0.2)), 0.8)
        let clank = mul(tone(180, n(0.18), square: true), env(n(0.18), attack: 0.002, decay: 0.05))
        make("siege", hiss + clank, 0.3)
        make("pop", mul(tone(660, n(0.08)), env(n(0.08), decay: 0.03)), 0.25)
        make("click", mul(tone(1200, n(0.03)), env(n(0.03), decay: 0.01)), 0.15)
        make("victory", [523.0, 659, 784, 1046].flatMap { mul(tone($0, n(0.18)), env(n(0.18), decay: 0.2)) }, 0.3)
        make("defeat", [392.0, 330, 262].flatMap { gain(mul(tone($0, n(0.3), square: true), env(n(0.3), decay: 0.3)), 0.4) }, 0.25)
        return out
    }

    // MARK: Playback

    /// Builds the buffers and starts the engine. Safe to call repeatedly; silent if no output device exists.
    static func setup() {
        guard !attempted, !Debug.headless else { return }
        attempted = true
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let engine = AVAudioEngine()
        for (name, samples) in synthesise() {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
            buffers[name] = buf
        }
        for _ in 0..<16 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        do {
            try engine.start()
            self.engine = engine
            ready = true
        } catch {
            buffers = [:]
            players = []
        }
    }

    static func play(_ name: String, minGap: Double = 0) {
        guard Settings.sound, !Debug.headless else { return }
        setup()
        guard ready, let buf = buffers[name] else { return }
        let now = CACurrentMediaTime()
        if minGap > 0, let last = lastPlayed[name], now - last < minGap { return }
        lastPlayed[name] = now
        let node = players[next % players.count]
        next += 1
        node.stop()
        node.scheduleBuffer(buf, completionHandler: nil)
        node.play()
    }
}
