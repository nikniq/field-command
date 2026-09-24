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

    fileprivate static var engine: AVAudioEngine?
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

    // MARK: Music

    /// Procedural ambient music, layered by threat — music.py's recipe: a pad (always on), a pulse that comes
    /// up as the enemy comes into view, drums that come up when your forces are fighting.
    enum Music {
        static let loopSeconds = 8.0
        static let bpm = 100.0
        static let layers = ["pad", "pulse", "drums"]
        static let master: Float = 0.32
        static let rise = 1.0, fall = 6.0
        static let alertHold = 12.0, shotHold = 4.0
        static let threatAlert = 1.0, threatShots = 0.7, threatSeen = 0.4
        static let shots: Set<String> = ["rifle", "cannon", "turret", "snipe", "explosion"]

        static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let t = min(1, max(0, (x - e0) / (e1 - e0)))
            return t * t * (3 - 2 * t)
        }

        /// Per-layer gain for a threat level in 0..1.
        static func layerGains(_ threat: Double) -> [String: Double] {
            ["pad": 1, "pulse": smooth(0.2, 0.6, threat), "drums": smooth(0.55, 1.0, threat)]
        }

        /// What the player is facing, as a number: 1 under attack, 0.7 while shots are heard, 0.4 with an
        /// enemy in sight, else 0 — smoothed so the music breathes rather than flickers.
        struct Threat {
            var level = 0.0
            var lastAlert = -1e9
            var lastShot = -1e9
            var enemiesSeen = 0

            mutating func note(_ kind: String, _ now: Double) {
                if kind == "alert" { lastAlert = now } else if shots.contains(kind) { lastShot = now }
            }

            func target(_ now: Double) -> Double {
                if now - lastAlert < alertHold { return threatAlert }
                if now - lastShot < shotHold { return threatShots }
                return enemiesSeen > 0 ? threatSeen : 0
            }

            @discardableResult
            mutating func update(_ dt: Double, _ now: Double) -> Double {
                let t = target(now)
                let k = min(1, dt / (t > level ? rise : fall))
                level += (t - level) * k
                return level
            }
        }

        private static func tone(_ freq: Double, _ count: Int) -> [Double] {
            (0..<count).map { sin(2 * .pi * freq * Double($0) / rate) }
        }

        private static func env(_ count: Int, _ attack: Double, _ decay: Double) -> [Double] {
            (0..<count).map { i in let t = Double(i) / rate; return min(1, t / max(attack, 1e-4)) * exp(-t / decay) }
        }

        private static func lowpass(_ x: [Double], _ k: Double) -> [Double] {
            var acc = 0.0
            return x.map { v in acc += k * (v - acc); return acc }
        }

        /// The three loops as samples in [-1, 1], each loopSeconds long and seamless.
        static func synthesise() -> [String: [Float]] {
            let n = Int(rate * loopSeconds)
            let beat = 60.0 / bpm
            var rng = Noise(state: 0xD1B54A32D192ED03)
            // Pad: A minor, two octaves apart, each voice slightly detuned so it slowly beats; a breath every loop.
            var pad = [Double](repeating: 0, count: n)
            for (f, g) in [(110.0, 0.5), (110.6, 0.5), (164.8, 0.35), (220.0, 0.25), (261.6, 0.2), (329.6, 0.15)] {
                let t = tone(f, n)
                for i in 0..<n { pad[i] += t[i] * g }
            }
            for i in 0..<n {
                let t = Double(i) / rate
                pad[i] *= 0.55 + 0.45 * sin(2 * .pi * t / loopSeconds - .pi / 2) * 0.5 + 0.25
            }
            pad = lowpass(pad, 0.12)
            // Pulse: a bass note every beat over A - C - E - D, softened, with a little grit.
            var pulse = [Double](repeating: 0, count: n)
            let notes = [55.0, 65.4, 82.4, 73.4]
            let step = Int(rate * beat)
            let beats = Int(loopSeconds / beat)
            for i in 0..<beats {
                let f = notes[(i / 2) % notes.count]
                let seg = min(step, n - i * step)
                let e = env(seg, 0.01, 0.22), t1 = tone(f, seg), t2 = tone(f * 2, seg)
                let g = i % 2 == 0 ? 1.0 : 0.7
                for j in 0..<seg {
                    let sq: Double = t2[j] > 0 ? 1 : (t2[j] < 0 ? -1 : 0)
                    pulse[i * step + j] += (t1[j] + 0.4 * sq) * e[j] * g
                }
            }
            pulse = lowpass(pulse, 0.2)
            // Drums: a kick on the beat (a sine sweeping down), hats off the beat, a snare on 2 and 4.
            var drums = [Double](repeating: 0, count: n)
            for i in 0..<beats {
                let s = i * step
                let kn = min(Int(rate * 0.25), n - s)
                var phase = 0.0
                let ke = env(kn, 0.002, 0.09)
                for j in 0..<kn {
                    let sweep = 120 * exp(-Double(j) / rate * 18) + 40
                    phase += sweep
                    drums[s + j] += sin(2 * .pi * phase / rate) * ke[j] * 1.2
                }
                let hs = s + step / 2
                let hn = min(Int(rate * 0.06), n - hs)
                if hn > 0 {
                    let he = env(hn, 0.001, 0.02)
                    for j in 0..<hn { drums[hs + j] += Double(rng.next()) * he[j] * 0.35 }
                }
                if i % 2 == 1 {
                    let sn = min(Int(rate * 0.16), n - s)
                    let se = env(sn, 0.002, 0.05)
                    let body = lowpass((0..<sn).map { _ in Double(rng.next()) }, 0.5)
                    for j in 0..<sn { drums[s + j] += body[j] * se[j] * 0.6 }
                }
            }
            var out: [String: [Float]] = [:]
            let fade = Int(rate * 0.02)
            let mixes: [(String, [Double], Double)] = [("pad", pad, 0.22), ("pulse", pulse, 0.5), ("drums", drums, 0.7)]
            for (name, x, vol) in mixes {
                var y = x.map { $0 * vol }
                for j in 0..<fade {
                    y[n - fade + j] *= 1 - Double(j) / Double(fade - 1)
                    y[j] *= Double(j) / Double(fade - 1)
                }
                out[name] = y.map { Float(max(-1, min(1, $0))) }
            }
            return out
        }

        // Playback: one looping player per layer; gains follow the threat level each frame.
        private static var nodes: [String: AVAudioPlayerNode] = [:]
        private static var started = false
        private static var paused = false

        static func update(_ threat: Double) {
            guard !Debug.headless else { return }
            guard Settings.sound, Settings.music else {
                if started && !paused { for (_, p) in nodes { p.pause() }; paused = true }
                return
            }
            Audio.setup()
            guard ready, let engine = Audio.engine, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
            if !started {
                for (name, samples) in synthesise() {
                    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
                    buf.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
                    let p = AVAudioPlayerNode()
                    engine.attach(p)
                    engine.connect(p, to: engine.mainMixerNode, format: format)
                    p.volume = 0
                    p.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
                    p.play()
                    nodes[name] = p
                }
                started = true
            } else if paused {
                for (_, p) in nodes { p.play() }
                paused = false
            }
            for (name, g) in layerGains(threat) { nodes[name]?.volume = Float(g) * master }
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
