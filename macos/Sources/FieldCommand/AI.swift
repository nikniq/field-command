import SpriteKit

/// Computer opponent: runs an economy, follows a timed build plan, defends its base and sends escalating attack waves.
final class AI {
    unowned let game: GameScene
    let team: Team
    private var think: CGFloat = 1
    private var waveSize: Int
    private var nextWave: CGFloat
    private var attackers: [Unit] = []

    init(game: GameScene, team: Team = .enemy) {
        self.game = game
        self.team = team
        waveSize = game.difficulty.initialWave
        nextWave = game.difficulty.firstAttack
    }

    private var diff: Difficulty { game.difficulty }

    func update(_ dt: CGFloat) {
        think -= dt
        guard think <= 0 else { return }
        think = 0.5

        let mine = game.units.filter { $0.team == team }
        let bases = game.buildings.filter { $0.team == team }
        guard !bases.isEmpty else { return }
        let hq = bases.first { $0.kind == .hq } ?? bases[0]
        let workers = mine.filter { $0.kind == .worker }
        let army = mine.filter { $0.kind != .worker }
        attackers.removeAll { $0.dead }
        let home = army.filter { u in !attackers.contains { $0 === u } }

        let dropoffs = bases.filter { $0.kind == .hq && $0.built }
        for w in workers where w.order.isIdle {
            // Prefer crystal near any finished HQ, closest to this worker.
            let served = game.crystals.filter { c in !c.dead && dropoffs.contains { $0.position.distance(to: c.position) < 700 } }
            if let c = served.min(by: { $0.position.distance(to: w.position) < $1.position.distance(to: w.position) })
                ?? game.nearestCrystal(to: w.position, within: 6000) {
                w.command(.gather(c))
            }
        }

        let reserve = construct(hq: hq, bases: bases, workers: workers, armyCount: army.count)
        produce(hq: hq, bases: bases, workers: workers, reserve: reserve)
        defend(bases: bases, home: home)
        attack(hq: hq, home: home)
    }

    private func pendingCount(_ k: BuildingKind, _ workers: [Unit]) -> Int {
        workers.filter { if case .build(let bk, _) = $0.order { return bk == k }; return false }.count
    }

    /// Starts at most one construction per tick. Returns crystal to hold back for a planned building.
    private func construct(hq: Building, bases: [Building], workers: [Unit], armyCount: Int) -> CGFloat {
        let t = game.elapsed / diff.pace
        func count(_ k: BuildingKind) -> Int { bases.filter { $0.kind == k }.count + pendingCount(k, workers) }

        let used = game.supplyUsed(team)
        let pendingSupply = bases.filter { !$0.built }.reduce(0) { $0 + $1.stats.supply } + pendingCount(.depot, workers) * 8
        let cap = game.supplyCap(team) + pendingSupply
        let producers = bases.filter { $0.kind == .barracks || $0.kind == .factory || $0.kind == .hq }.count

        var want: BuildingKind?
        var site: CGPoint?
        let bank = game.resources[team.rawValue]
        if cap < 200 && cap - used < 4 + producers * 3 && pendingCount(.depot, workers) < (bank > 400 ? 2 : 1) {
            want = .depot
        } else if count(.hq) < 3, t > 300 || homeCrystalLeft(bases) < 5000, let e = expansionSite(from: hq.position) {
            want = .hq
            site = e
        } else {
            let plan: [(BuildingKind, Int)] = [
                (.barracks, t > 35 ? 1 : 0),
                (.turret, t > 140 ? 1 : 0),
                (.factory, t > 170 ? 1 : 0),
                (.barracks, t > 230 ? 2 : 0),
                (.turret, t > 300 ? 2 : 0),
                (.factory, t > 420 ? 2 : 0),
                (.barracks, t > 520 ? 3 : 0),
                (.turret, t > 560 ? 4 : 0),
            ]
            for (k, n) in plan where n > 0 && count(k) < n {
                if let r = k.stats.requires, !game.hasBuilt(r, team: team) { continue }
                want = k
                break
            }
            // Floating crystal: add production so income actually gets spent.
            if want == nil && bank > 450 && game.hasBuilt(.barracks, team: team) {
                if count(.factory) < 3 && count(.factory) * 2 < count(.barracks) {
                    want = .factory
                } else if count(.barracks) < 6 {
                    want = .barracks
                }
            }
        }
        guard let k = want, !workers.isEmpty else { return 0 }
        let cost = CGFloat(k.stats.cost)
        guard game.resources[team.rawValue] >= cost else { return cost }
        let candidates = workers.filter { if case .build = $0.order { return false }; return true }
        guard let builder = candidates.min(by: { $0.position.distance(to: hq.position) < $1.position.distance(to: hq.position) }),
              let spot = site ?? findSpot(k, near: hq.position) else { return 0 }
        game.resources[team.rawValue] -= cost
        builder.orderBuild(k, at: spot)
        return 0
    }

    private func homeCrystalLeft(_ bases: [Building]) -> Int {
        let hqs = bases.filter { $0.kind == .hq }
        return game.crystals.filter { c in !c.dead && hqs.contains { $0.position.distance(to: c.position) < 700 } }
            .reduce(0) { $0 + $1.amount }
    }

    /// Finds a buildable HQ spot beside the closest unclaimed crystal field.
    private func expansionSite(from home: CGPoint) -> CGPoint? {
        let claimed = game.buildings.filter { $0.kind == .hq }
        let pendingHQ = game.units.compactMap { u -> CGPoint? in
            if case .build(.hq, let p) = u.order { return p }
            return nil
        }
        let free = game.crystals.filter { c in
            !c.dead && !claimed.contains { $0.position.distance(to: c.position) < 800 } &&
                !pendingHQ.contains { $0.distance(to: c.position) < 800 }
        }
        guard let target = free.min(by: { $0.position.distance(to: home) < $1.position.distance(to: home) }) else { return nil }
        let field = free.filter { $0.position.distance(to: target.position) < 250 }
        let center = field.reduce(CGPoint.zero) { $0 + $1.position } * (1 / CGFloat(field.count))
        let toHome = (home - center).angle
        for i in 0..<16 {
            let a = toHome + CGFloat((i + 1) / 2) * (i % 2 == 0 ? 0.35 : -0.35)
            for d: CGFloat in [250, 290, 330] {
                let p = game.snapped(center + CGPoint(x: cos(a) * d, y: sin(a) * d))
                if game.canPlace(.hq, at: p, margin: 10) { return p }
            }
        }
        return nil
    }

    private func findSpot(_ k: BuildingKind, near c: CGPoint) -> CGPoint? {
        let toCenter = (CGPoint(x: worldSize.width / 2, y: worldSize.height / 2) - c).angle
        for attempt in 0..<90 {
            // Start near the HQ facing the map centre, then widen the search as the base fills up.
            let spread: CGFloat = k == .turret ? 0.7 : (attempt < 30 ? .pi * 0.65 : .pi)
            let a = toCenter + CGFloat.random(in: -spread...spread)
            let d = CGFloat.random(in: 190...(260 + CGFloat(attempt) * 8)) + (k == .turret ? 90 : 0)
            let p = game.snapped(c + CGPoint(x: cos(a) * d, y: sin(a) * d))
            let r = squareRect(center: p, half: k.stats.half)
            let clearOfMinerals = game.crystals.allSatisfy { rectDistance(r, $0.position) > 90 }
            if clearOfMinerals && game.canPlace(k, at: p, margin: attempt < 45 ? 26 : 14) { return p }
        }
        return nil
    }

    private func produce(hq: Building, bases: [Building], workers: [Unit], reserve: CGFloat) {
        let money = { self.game.resources[self.team.rawValue] - reserve }
        let queuedWorkers = hq.queue.filter { $0 == .worker }.count
        if hq.kind == .hq && hq.built && workers.count + queuedWorkers < diff.workerTarget && hq.queue.count < 2 {
            if workers.count < 8 || money() >= 50 { game.train(.worker, from: [hq], team: team) }
        }
        let toCenter = (CGPoint(x: worldSize.width / 2, y: worldSize.height / 2) - hq.position).normalized
        for b in bases where b.built && b.queue.isEmpty {
            if b.rally == nil && (b.kind == .barracks || b.kind == .factory) {
                b.rally = hq.position + toCenter * 260
            }
            if b.kind == .barracks && money() >= 50 {
                game.train(.marine, from: [b], team: team)
            } else if b.kind == .factory && money() >= 150 {
                game.train(.tank, from: [b], team: team)
            }
        }
    }

    private func defend(bases: [Building], home: [Unit]) {
        var threat: Unit?
        outer: for u in game.units where u.team.isHostile(to: team) {
            for b in bases where b.position.distance(to: u.position) < 650 {
                threat = u
                break outer
            }
        }
        guard let t = threat else { return }
        for u in home where u.order.isIdle || u.order.isMove {
            u.command(.attackMove(t.position))
        }
    }

    private func attack(hq: Building, home: [Unit]) {
        let overdue = game.elapsed > nextWave + 120 && home.count >= 4
        if game.elapsed >= nextWave && (home.count >= waveSize || overdue) {
            if let target = game.primaryTarget(for: team, from: hq.position) {
                for u in home { u.command(.attackMove(target.position)) }
                attackers += home
                waveSize = min(40, waveSize + 2 + diff.rawValue * 2)
                nextWave = game.elapsed + 50
                if team == .enemy { game.enemyWaveLaunched() }
            }
        }
        for u in attackers where u.order.isIdle {
            if let t = game.primaryTarget(for: team, from: u.position) { u.command(.attackMove(t.position)) }
        }
    }
}
