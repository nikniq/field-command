import AVFoundation
import Foundation

/// Procedurally synthesised sound effects — the same thirteen recipes as the Linux edition's audio.py, so both
/// platforms sound alike and no audio files are shipped. Buffers are made once, then played from a small pool
/// of player nodes; rapid repeats of the same effect are throttled by `minGap`, as in the Python edition.
enum Audio {
    static let rate = 22050.0
    static let names = ["rifle", "cannon", "explosion", "turret", "complete", "alert", "wave", "snipe", "siege",
                        "pop", "click", "victory", "defeat"] + voicePitch.keys.sorted().flatMap { ["voice_\($0)", "ack_\($0)"] }
    /// Unit voices: a radio acknowledgement per kind — two tones when selected, a quick one on an order. The
    /// base pitch tells the kinds apart; audio.py's VOICE_PITCH has the same numbers.
    static let voicePitch: [String: Double] = ["worker": 520, "marine": 440, "tank": 200, "sniper": 660, "medic": 590, "gunship": 360]
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
        for kind in voicePitch.keys.sorted() {
            make("voice_\(kind)", voice(voicePitch[kind]!, ack: false, &rng), 0.3)
            make("ack_\(kind)", voice(voicePitch[kind]!, ack: true, &rng), 0.3)
        }
        return out
    }

    /// A radio call: a squelch click, then tones with a little vibrato through a band-limited 'speaker' — two
    /// rising notes for a selection, one quick falling note for an acknowledgement.
    private static func voice(_ f0: Double, ack: Bool, _ rng: inout Noise) -> [Float] {
        var parts: [Float] = mul(noise(n(0.03), &rng), env(n(0.03), attack: 0.001, decay: 0.008)).map { $0 * 0.6 }
        let notes: [(Double, Double)] = ack ? [(f0 * 1.5, 0.07), (f0 * 1.1, 0.09)] : [(f0, 0.09), (f0 * 1.25, 0.12)]
        for (f, secs) in notes {
            let m = n(secs)
            var phase = 0.0
            var t = [Float](repeating: 0, count: m)
            for i in 0..<m {
                let tt = Double(i) / rate
                phase += f * (1 + 0.02 * sin(2 * .pi * 40 * tt))
                let s = sin(2 * .pi * phase / rate)
                t[i] = Float(s + 0.35 * (s > 0 ? 1 : (s < 0 ? -1 : 0)) * (1 - tt / secs))
            }
            parts += mul(lowpass(t, 0.35), env(m, attack: 0.006, decay: secs * 0.6))
            parts += [Float](repeating: 0, count: n(0.02))
        }
        parts += mul(noise(n(0.02), &rng), env(n(0.02), attack: 0.001, decay: 0.006)).map { $0 * 0.4 }
        return parts
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
        static let bpm = 100.0
        static let beats = 32                    // four chords of eight beats: A minor, F, C, G
        static let loopSeconds = Double(beats) * 60.0 / bpm    // 19.2 s
        static let layers = ["pad", "melody", "pulse", "drums", "brass"]
        /// The progression, as (root, third, fifth) in Hz, low: Am, F, C, G — music.py's CHORDS.
        static let chords: [(Double, Double, Double)] = [(110.0, 130.81, 164.81), (87.31, 110.0, 130.81), (130.81, 164.81, 196.0), (98.0, 123.47, 146.83)]
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
            ["pad": 1, "melody": 1 - smooth(0.35, 0.75, threat), "pulse": smooth(0.2, 0.6, threat),
             "drums": smooth(0.55, 1.0, threat), "brass": smooth(0.8, 1.0, threat)]
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

        private static func pluck(_ freq: Double, _ count: Int) -> [Double] {
            (0..<count).map { i in
                let t = Double(i) / rate
                let env = min(1, t / 0.008) * exp(-t / 0.28)
                return (sin(2 * .pi * freq * t) + 0.3 * sin(2 * .pi * freq * 2 * t)) * env
            }
        }

        /// The five loops as samples in [-1, 1], each loopSeconds long and seamless: a chord progression over
        /// four bars — A minor, F, C, G — at 100 beats a minute (music.py's recipe).
        static func synthesise() -> [String: [Float]] {
            let n = Int(rate * loopSeconds)
            let beat = 60.0 / bpm
            let step = Int(rate * beat)
            let bar = step * 8
            var rng = Noise(state: 0xD1B54A32D192ED03)
            // Pad: every chord sustained over its bar, voices detuned so they slowly beat, crossfading at the bar line.
            var pad = [Double](repeating: 0, count: n)
            for (ci, ch) in chords.enumerated() {
                let voices: [(Double, Double)] = [(ch.0, 0.5), (ch.0 * 1.004, 0.45), (ch.1, 0.3), (ch.2, 0.3), (ch.0 * 2, 0.2)]
                let t0 = Double(ci) * beat * 8, t1 = Double(ci + 1) * beat * 8 + 0.4
                for i in 0..<n {
                    let t = Double(i) / rate
                    let fade = min(1, max(0, (t - t0) / 1.5)) * min(1, max(0, (t1 - t) / 1.5))
                    if fade <= 0 { continue }
                    var v = 0.0
                    for (f, g) in voices { v += sin(2 * .pi * f * t) * g }
                    pad[i] += v * fade
                }
            }
            for i in 0..<n { pad[i] *= 0.8 + 0.2 * sin(2 * .pi * Double(i) / rate / 6.0) }
            pad = lowpass(pad, 0.12)
            // Melody: a plucked arpeggio over each chord's tones, eighth notes, with a soft echo — the calm layer.
            var melody = [Double](repeating: 0, count: n)
            let pattern = [0, 2, 1, 2, 3, 2, 1, 2, 0, 1, 2, 3, 2, 1, 2, 1]
            for (ci, ch) in chords.enumerated() {
                let tones = [ch.0 * 2, ch.1 * 2, ch.2 * 2, ch.0 * 4]
                for k in 0..<16 {
                    let start = ci * bar + k * step / 2
                    let m = min(Int(rate * 0.5), n - start)
                    if m <= 0 { continue }
                    let p = pluck(tones[pattern[k]], m)
                    let g = k % 4 == 0 ? 0.9 : 0.6
                    for q in 0..<m { melody[start + q] += p[q] * g }
                }
            }
            let d = Int(rate * beat * 0.75)
            var echoed = melody
            for i in d..<n { echoed[i] += melody[i - d] * 0.35 }
            melody = echoed
            // Pulse: a bass note every beat on the chord's root, softened, with a little grit.
            var pulse = [Double](repeating: 0, count: n)
            for (ci, ch) in chords.enumerated() {
                for k in 0..<8 {
                    let f = ch.0 / 2
                    let start = ci * bar + k * step
                    let seg = min(step, n - start)
                    let e = env(seg, 0.01, 0.22), t1 = tone(f, seg), t2 = tone(f * 2, seg)
                    let g = k % 2 == 0 ? 1.0 : 0.7
                    for q in 0..<seg {
                        let sq: Double = t2[q] > 0 ? 1 : (t2[q] < 0 ? -1 : 0)
                        pulse[start + q] += (t1[q] + 0.4 * sq) * e[q] * g
                    }
                }
            }
            pulse = lowpass(pulse, 0.2)
            // Drums: a kick on the beat, hats off the beat, a snare on two and four, and a fill at the turn.
            var drums = [Double](repeating: 0, count: n)
            for k in 0..<beats {
                let s = k * step
                let kn = min(Int(rate * 0.25), n - s)
                var phase = 0.0
                let ke = env(kn, 0.002, 0.09)
                for q in 0..<kn {
                    let sweep = 120 * exp(-Double(q) / rate * 18) + 40
                    phase += sweep
                    drums[s + q] += sin(2 * .pi * phase / rate) * ke[q] * 1.2
                }
                let hs = s + step / 2
                let hn = min(Int(rate * 0.06), n - hs)
                if hn > 0 {
                    let he = env(hn, 0.001, 0.02)
                    for q in 0..<hn { drums[hs + q] += Double(rng.next()) * he[q] * 0.35 }
                }
                if k % 2 == 1 {
                    let sn = min(Int(rate * 0.16), n - s)
                    let se = env(sn, 0.002, 0.05)
                    let body = lowpass((0..<sn).map { _ in Double(rng.next()) }, 0.5)
                    for q in 0..<sn { drums[s + q] += body[q] * se[q] * 0.6 }
                }
                if k >= beats - 2 {
                    for f in 0..<4 {
                        let qs = s + f * step / 4
                        let qn = min(Int(rate * 0.1), n - qs)
                        if qn <= 0 { continue }
                        let qe = env(qn, 0.002, 0.04)
                        let body = lowpass((0..<qn).map { _ in Double(rng.next()) }, 0.5)
                        for q in 0..<qn { drums[qs + q] += body[q] * qe[q] * 0.45 }
                    }
                }
            }
            // Brass: a sawtooth swell on the chord every four beats, only at the very top of the threat.
            var brass = [Double](repeating: 0, count: n)
            for (ci, ch) in chords.enumerated() {
                for k in [0, 4] {
                    let start = ci * bar + k * step
                    let seg = min(step * 3, n - start)
                    for q in 0..<seg {
                        let tt = Double(q) / rate
                        let e = min(1, tt / 0.35) * exp(-max(0, tt - 1.2) / 0.5)
                        var v = 0.0
                        for (f, g) in [(ch.0, 0.5), (ch.1, 0.35), (ch.2, 0.35)] {
                            v += (2 * ((f * tt).truncatingRemainder(dividingBy: 1)) - 1) * g
                        }
                        brass[start + q] += v * e
                    }
                }
            }
            brass = lowpass(brass, 0.08)
            var out: [String: [Float]] = [:]
            let fade = Int(rate * 0.02)
            let mixes: [(String, [Double], Double)] = [("pad", pad, 0.22), ("melody", melody, 0.34), ("pulse", pulse, 0.5),
                                                       ("drums", drums, 0.7), ("brass", brass, 0.55)]
            for (name, x, vol) in mixes {
                var y = x.map { $0 * vol }
                for q in 0..<fade {
                    y[n - fade + q] *= 1 - Double(q) / Double(fade - 1)
                    y[q] *= Double(q) / Double(fade - 1)
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
