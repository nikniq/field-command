import SpriteKit

/// Shared helpers for the simple button/field UI used by the multiplayer screens.
private final class UIBuilder {
    var buttons: [(CGRect, () -> Void)] = []
    let root: SKNode

    init(root: SKNode) { self.root = root }

    func reset() {
        root.removeAllChildren()
        buttons = []
    }

    @discardableResult
    func label(_ text: String, _ size: CGFloat, _ color: NSColor, at p: CGPoint, font: String = Fonts.medium,
               align: SKLabelHorizontalAlignmentMode = .left) -> SKLabelNode {
        let l = makeLabel(text, size: size, color: color, font: font, align: align, valign: .center)
        l.position = p
        root.addChild(l)
        return l
    }

    func panel(_ r: CGRect) {
        let p = SKSpriteNode(texture: Art.panel(r.size, radius: 12))
        p.size = r.size
        p.position = CGPoint(x: r.midX, y: r.midY)
        root.addChild(p)
    }

    func button(_ r: CGRect, _ title: String, mouse: CGPoint?, enabled: Bool = true, accent: Bool = false, size: CGFloat = 15,
                action: @escaping () -> Void) {
        let hover = enabled && (mouse.map { r.contains($0) } ?? false)
        let state: Art.ButtonState = !enabled ? .disabled : (hover ? .hover : (accent ? .active : .normal))
        let bg = SKSpriteNode(texture: Art.button(r.size, state, accent: accent ? Palette.amber : Palette.buttonEdge))
        bg.size = r.size
        bg.position = CGPoint(x: r.midX, y: r.midY)
        root.addChild(bg)
        label(title, size, enabled ? Palette.text : Palette.dim, at: CGPoint(x: r.midX, y: r.midY), font: Fonts.bold, align: .center)
        if enabled { buttons.append((r, action)) }
    }

    func field(_ r: CGRect, _ caption: String, text: String, placeholder: String, focused: Bool, mouse: CGPoint?) {
        let bg = SKSpriteNode(texture: Art.button(r.size, focused ? .hover : .normal))
        bg.size = r.size
        bg.position = CGPoint(x: r.midX, y: r.midY)
        root.addChild(bg)
        label(caption, 11, Palette.dim, at: CGPoint(x: r.minX, y: r.maxY + 12), font: Fonts.bold)
        let caret = focused && Int(Date().timeIntervalSince1970 * 2) % 2 == 0 ? "|" : ""
        label(text.isEmpty && !focused ? placeholder : text + caret, 15, text.isEmpty ? Palette.dim : Palette.text,
              at: CGPoint(x: r.minX + 12, y: r.midY))
    }

    func click(_ p: CGPoint) -> Bool {
        for (r, action) in buttons where r.contains(p) {
            playSound("Tink")
            action()
            return true
        }
        return false
    }
}

private func addBackdrop(to scene: SKScene) {
    let w = scene.size.width, h = scene.size.height
    var y = -h / 2
    while y < h / 2 {
        var x = -w / 2
        while x < w / 2 {
            let s = SKSpriteNode(texture: Art.ground())
            s.anchorPoint = .zero
            s.size = CGSize(width: 1024, height: 1024)
            s.position = CGPoint(x: x, y: y)
            s.zPosition = -10
            scene.addChild(s)
            x += 1024
        }
        y += 1024
    }
    let dim = SKSpriteNode(color: NSColor(white: 0, alpha: 0.68), size: scene.size)
    dim.zPosition = -5
    scene.addChild(dim)
    let v = SKSpriteNode(texture: Art.vignette)
    v.size = CGSize(width: w * 1.15, height: h * 1.15)
    v.zPosition = -4
    scene.addChild(v)
}

/// Presents a scene with a short fade (instantly in headless test mode, where transitions never advance).
func showScene(_ view: SKView?, _ scene: SKScene, fade: TimeInterval = 0.3) {
    if Debug.instantScenes { view?.presentScene(scene) } else { view?.presentScene(scene, transition: .fade(withDuration: fade)) }
}

func stopHostedServer() {
    GameServer.hosted?.stop()
    GameServer.hosted = nil
}

/// Best guess at this Mac's LAN address, for telling other players where to connect.
func localIPAddress() -> String {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return "127.0.0.1" }
    defer { Darwin.close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(1).bigEndian
    addr.sin_addr.s_addr = inet_addr("10.255.255.255")
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard ok == 0 else { return "127.0.0.1" }
    var local = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return String(cString: inet_ntoa(local.sin_addr))
}

private func mouseLocation(in scene: SKScene) -> CGPoint? {
    guard let v = scene.view, let win = v.window else { return nil }
    return scene.convertPoint(fromView: v.convert(win.mouseLocationOutsideOfEventStream, from: nil))
}

// MARK: - Host / join / LAN browser

final class MultiplayerScene: SKScene {
    private let content = SKNode()
    private lazy var ui = UIBuilder(root: content)
    private var playerName = UserDefaults.standard.string(forKey: "playerName") ?? NSFullUserName().components(separatedBy: " ").first ?? "Commander"
    private var address = UserDefaults.standard.string(forKey: "lastAddress") ?? ""
    private var focus: Int? = nil  // 0 name, 1 address
    private var status: String
    private var statusBad: Bool
    private let browser = LanBrowser()
    private var nameRect = CGRect.zero, addrRect = CGRect.zero
    private var refresh: TimeInterval = 0

    init(size: CGSize, message: String? = nil) {
        status = message ?? ""
        statusBad = message != nil
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMove(to view: SKView) {
        backgroundColor = .rgb(0.03, 0.04, 0.05)
        rebuild()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        if view != nil { rebuild() }
    }

    private func rebuild() {
        removeAllChildren()
        addBackdrop(to: self)
        addChild(content)
        content.zPosition = 10
        draw(mouse: mouseLocation(in: self))
    }

    private func draw(mouse: CGPoint?) {
        ui.reset()
        let h = size.height
        ui.label("MULTIPLAYER", 44, Palette.text, at: CGPoint(x: 0, y: h / 2 - 80), font: Fonts.heavy, align: .center)
        ui.label("Up to 4 players · free-for-all or teams · Mac and Linux players can host and join each other", 14, Palette.dim,
                 at: CGPoint(x: 0, y: h / 2 - 122), align: .center)
        let colW: CGFloat = 460, top = h / 2 - 170
        let left = CGRect(x: -colW - 20, y: top - 380, width: colW, height: 380)
        ui.panel(left)
        nameRect = CGRect(x: left.minX + 24, y: top - 90, width: colW - 48, height: 40)
        ui.field(nameRect, "YOUR NAME", text: playerName, placeholder: "Your name", focused: focus == 0, mouse: mouse)
        addrRect = CGRect(x: left.minX + 24, y: top - 190, width: colW - 48, height: 40)
        ui.field(addrRect, "JOIN BY ADDRESS", text: address, placeholder: "IP address, e.g. 192.168.1.20", focused: focus == 1, mouse: mouse)
        ui.button(CGRect(x: left.minX + 24, y: top - 250, width: colW - 48, height: 44), "Join", mouse: mouse) { [unowned self] in
            self.join(self.address)
        }
        ui.label("HOST A GAME", 13, Palette.amber, at: CGPoint(x: left.minX + 24, y: top - 290), font: Fonts.bold)
        ui.label("Others join at \(localIPAddress()):\(NetProtocol.gamePort)", 12, Palette.dim, at: CGPoint(x: left.minX + 24, y: top - 312))
        ui.button(CGRect(x: left.minX + 24, y: top - 366, width: colW - 48, height: 44), "Host Game", mouse: mouse, accent: true) { [unowned self] in
            self.host()
        }

        let right = CGRect(x: 20, y: top - 380, width: colW, height: 380)
        ui.panel(right)
        ui.label("GAMES ON YOUR NETWORK", 13, Palette.amber, at: CGPoint(x: right.minX + 24, y: top - 28), font: Fonts.bold)
        let games = browser.list()
        if !browser.running {
            ui.label("LAN discovery unavailable (port in use?)", 13, Palette.bad, at: CGPoint(x: right.minX + 24, y: top - 64))
        } else if games.isEmpty {
            let dots = String(repeating: ".", count: 1 + Int(Date().timeIntervalSince1970 * 2.5) % 3)
            ui.label("Searching" + dots, 14, Palette.dim, at: CGPoint(x: right.minX + 24, y: top - 64))
            ui.label("Games hosted on this network appear here automatically.", 12, Palette.dim, at: CGPoint(x: right.minX + 24, y: top - 90))
        }
        for (i, g) in games.prefix(6).enumerated() {
            let r = CGRect(x: right.minX + 24, y: top - 100 - CGFloat(i) * 52, width: colW - 48, height: 44)
            let sub = "\(g.ip):\(g.port) · \(g.players) player(s) · " + (g.joinable ? "open" : (g.state == "lobby" ? "full" : "in progress"))
            ui.button(r, "", mouse: mouse, enabled: g.joinable) { [unowned self] in self.join("\(g.ip):\(g.port)") }
            ui.label(g.name, 14, g.joinable ? Palette.text : Palette.dim, at: CGPoint(x: r.minX + 14, y: r.midY + 8), font: Fonts.bold)
            ui.label(sub, 11, Palette.dim, at: CGPoint(x: r.minX + 14, y: r.midY - 10))
        }
        ui.button(CGRect(x: -100, y: top - 450, width: 200, height: 42), "Back", mouse: mouse) { [unowned self] in self.back() }
        if !status.isEmpty {
            ui.label(status, 14, statusBad ? Palette.bad : Palette.dim, at: CGPoint(x: 0, y: top - 490), font: Fonts.bold, align: .center)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        if currentTime - refresh > 0.2 {
            refresh = currentTime
            draw(mouse: mouseLocation(in: self))
        }
    }

    /// Test hook: presses "Host Game".
    func pressHost() { host() }

    private func host() {
        let player = playerName.trimmingCharacters(in: .whitespaces).isEmpty ? "Commander" : playerName
        if GameServer.hosted == nil {
            let server = GameServer(name: "\(player)'s game")
            server.log = { _ in }
            do {
                try server.start()
            } catch {
                status = error.localizedDescription
                statusBad = true
                return
            }
            GameServer.hosted = server
        }
        join("127.0.0.1:\(NetProtocol.gamePort)", hosting: true)
    }

    private func join(_ text: String, hosting: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else {
            status = "Enter the host's IP address, or pick a game from the list"
            statusBad = true
            return
        }
        let parts = t.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? UInt16(parts[1]) ?? NetProtocol.gamePort : NetProtocol.gamePort
        let player = playerName.trimmingCharacters(in: .whitespaces).isEmpty ? "Commander" : playerName
        UserDefaults.standard.set(player, forKey: "playerName")
        UserDefaults.standard.set(t, forKey: "lastAddress")
        do {
            let conn = try NetConnection(host: host, port: port)
            conn.send(["t": "hello", "name": player, "version": NetProtocol.version, "client": "mac"])
            browser.close()
            showScene(view, LobbyScene(size: size, conn: conn), fade: 0.3)
        } catch {
            if hosting { stopHostedServer() }
            status = error.localizedDescription
            statusBad = true
        }
    }

    private func back() {
        browser.close()
        showScene(view, MenuScene(size: size), fade: 0.3)
    }

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        focus = nameRect.contains(p) ? 0 : (addrRect.contains(p) ? 1 : nil)
        _ = ui.click(p)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: back()
        case 48: focus = focus == 0 ? 1 : 0
        case 36, 76:
            if focus == 1 { join(address) } else { focus = 1 }
        case 51:
            if focus == 0 { playerName = String(playerName.dropLast()) } else if focus == 1 { address = String(address.dropLast()) }
        default:
            guard let c = event.characters, c.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 }) else { return }
            if focus == 0 { playerName = String((playerName + c).prefix(20)) } else if focus == 1 { address = String((address + c).prefix(60)) }
        }
        draw(mouse: mouseLocation(in: self))
    }
}

// MARK: - Lobby

final class LobbyScene: SKScene {
    private let conn: NetConnection
    private var slot: Int?
    private var state: [String: Any]?
    private var error = ""
    private var chatLog: [(Int, String, String)] = []
    private var chatText: String?
    private let content = SKNode()
    private lazy var ui = UIBuilder(root: content)
    private var refresh: TimeInterval = 0

    init(size: CGSize, conn: NetConnection, slot: Int? = nil, initial: [String: Any]? = nil) {
        self.conn = conn
        self.slot = slot
        self.state = initial
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMove(to view: SKView) {
        backgroundColor = .rgb(0.03, 0.04, 0.05)
        rebuild()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        if view != nil { rebuild() }
    }

    private func rebuild() {
        removeAllChildren()
        addBackdrop(to: self)
        addChild(content)
        content.zPosition = 10
        draw(mouse: mouseLocation(in: self))
    }

    private var isHost: Bool {
        guard let s = slot, let st = state, let h = st["host_slot"] as? NSNumber else { return false }
        return h.intValue == s
    }

    private var ready: Bool {
        guard let s = slot, let st = state else { return false }
        let slots = jArr(st["slots"])
        return s < slots.count && ((jDict(slots[s])["ready"] as? Bool) ?? false)
    }

    private func send(_ m: [String: Any]) { conn.send(m) }

    /// Test hook: presses "Start Game" (host) or "Ready" (guest).
    func pressPrimary() {
        if isHost { send(["t": "start"]) } else { send(["t": "ready", "ready": true]) }
    }

    func leave() {
        conn.close()
        stopHostedServer()
        showScene(view, MultiplayerScene(size: size), fade: 0.3)
    }

    override func update(_ currentTime: TimeInterval) {
        for m in conn.messages() {
            switch jStr(m["t"]) {
            case "welcome": slot = jInt(m["slot"])
            case "lobby": state = m
            case "chat":
                chatLog.append((jInt(m["slot"]), jStr(m["name"]), jStr(m["text"])))
                chatLog = Array(chatLog.suffix(6))
                playSound("Pop")
            case "error": error = jStr(m["text"])
            case "start":
                let net = NetSession(conn: conn, start: m)
                let scene = GameScene(size: size, difficulty: net.difficulty, net: net)
                showScene(view, scene, fade: 0.5)
                return
            case "disconnected":
                stopHostedServer()
                showScene(view, MultiplayerScene(size: size, message: "Disconnected: \(jStr(m["text"]))"))
                return
            default: break
            }
        }
        if currentTime - refresh > 0.15 {
            refresh = currentTime
            draw(mouse: mouseLocation(in: self))
        }
    }

    private func draw(mouse: CGPoint?) {
        ui.reset()
        let h = size.height
        guard let st = state else {
            ui.label("Connecting…", 24, Palette.text, at: .zero, font: Fonts.bold, align: .center)
            if !error.isEmpty { ui.label(error, 15, Palette.bad, at: CGPoint(x: 0, y: -40), font: Fonts.bold, align: .center) }
            ui.button(CGRect(x: -90, y: -110, width: 180, height: 40), "Back", mouse: mouse) { [unowned self] in self.leave() }
            return
        }
        let difficulty = jInt(st["difficulty"])
        let diffName = (Difficulty(rawValue: difficulty) ?? .normal).name
        ui.label("LOBBY", 44, Palette.text, at: CGPoint(x: 0, y: h / 2 - 70), font: Fonts.heavy, align: .center)
        let address = GameServer.hosted != nil ? "others join at \(localIPAddress()):\(conn.port)" : "\(conn.host):\(conn.port)"
        ui.label("\(jStr(st["name"]))   ·   \(address)", 14, Palette.dim, at: CGPoint(x: 0, y: h / 2 - 110), align: .center)
        // Twelve slots are laid out in two columns of six; smaller lobbies keep the single wide column.
        let slotCount = jArr(st["slots"]).count
        let cols = slotCount > 6 ? 2 : 1
        let rowCount = (slotCount + cols - 1) / cols
        let pw = min(cols == 2 ? 1120 : 820, size.width - 40)
        let cw = pw / CGFloat(cols)
        let rh: CGFloat = cols == 2 ? 44 : 64
        let px = -pw / 2, top = h / 2 - 150
        ui.panel(CGRect(x: px, y: top - CGFloat(rowCount) * rh - 40, width: pw, height: CGFloat(rowCount) * rh + 40))
        for c in 0..<cols {
            let hx = px + CGFloat(c) * cw
            ui.label("PLAYER", 11, Palette.dim, at: CGPoint(x: hx + 54, y: top - 20), font: Fonts.bold)
            ui.label("TEAM", 11, Palette.dim, at: CGPoint(x: hx + cw - 210, y: top - 20), font: Fonts.bold)
            ui.label("STATUS", 11, Palette.dim, at: CGPoint(x: hx + cw - 100, y: top - 20), font: Fonts.bold)
        }
        let hostSlot = (st["host_slot"] as? NSNumber)?.intValue
        for (i, raw) in jArr(st["slots"]).enumerated() {
            let s = jDict(raw)
            let col = cols == 2 ? i / rowCount : 0
            let row = cols == 2 ? i % rowCount : i
            let hx = px + CGFloat(col) * cw
            let y = top - 20 - rh / 2 - CGFloat(row) * rh
            let bh = rh - 12
            let dot = SKShapeNode(circleOfRadius: cols == 2 ? 10 : 12)
            dot.fillColor = Team(rawValue: i).color
            dot.strokeColor = .clear
            dot.position = CGPoint(x: hx + 30, y: y)
            content.addChild(dot)
            let kind = jStr(s["kind"])
            var name: String
            switch kind {
            case "human": name = jStr(s["name"]) + (i == slot ? "  (you)" : "") + (i == hostSlot ? "  · host" : "")
            case "ai": name = "\(jStr(s["name"]).isEmpty ? "Computer" : jStr(s["name"])) (\(diffName))"
            case "open": name = "Open"
            default: name = "Closed"
            }
            ui.label(name, cols == 2 ? 14 : 16, kind == "human" || kind == "ai" ? Palette.text : Palette.dim,
                     at: CGPoint(x: hx + 50, y: y + 7), font: kind == "human" ? Fonts.bold : Fonts.medium)
            ui.label(Team.colorName(i), cols == 2 ? 10 : 11, Palette.dim, at: CGPoint(x: hx + 50, y: y - 10))
            if isHost && kind != "human" {
                let label = ["ai": "Computer", "open": "Open", "closed": "Closed"][kind] ?? kind
                ui.button(CGRect(x: hx + cw - 320, y: y - bh / 2, width: 100, height: bh), label, mouse: mouse, size: 12) { [unowned self] in
                    let order = ["open", "ai", "closed"]
                    let next = order[((order.firstIndex(of: kind) ?? 0) + 1) % 3]
                    self.send(["t": "slot", "slot": i, "kind": next])
                }
            }
            if kind == "human" || kind == "ai" {
                let team = jInt(s["team"])
                ui.button(CGRect(x: hx + cw - 210, y: y - bh / 2, width: 92, height: bh), "Team \(team)", mouse: mouse,
                          enabled: isHost || i == slot, size: 12) { [unowned self] in
                    self.send(["t": "slot", "slot": i, "team": team % maxPlayers + 1])
                }
                let (status, color): (String, NSColor) = kind == "ai" ? ("Ready", Palette.good)
                    : (i == hostSlot ? ("Host", Palette.amber) : ((s["ready"] as? Bool) == true ? ("Ready", Palette.good) : ("Not ready", Palette.dim)))
                ui.label(status, cols == 2 ? 12 : 14, color, at: CGPoint(x: hx + cw - 100, y: y), font: Fonts.bold)
            }
        }
        let by = top - CGFloat(rowCount) * rh - 80
        let mapId = (st["map"] as? String) ?? "auto"
        var mapLabel = "Map: " + ((st["map_name"] as? String) ?? "Auto (by player count)")
        if mapId != "auto" { mapLabel += "  (\(jInt(st["map_players"])) players)" }
        if isHost {
            ui.button(CGRect(x: px, y: by - 74, width: 492, height: 40), mapLabel, mouse: mouse) { [unowned self] in
                let ids = ["auto"] + SMapGen.catalog.map { $0.id }
                self.send(["t": "map", "id": ids[((ids.firstIndex(of: mapId) ?? -1) + 1) % ids.count]])
            }
            ui.button(CGRect(x: px, y: by - 20, width: 180, height: 40), "AI: \(diffName)", mouse: mouse) { [unowned self] in
                self.send(["t": "difficulty", "index": (difficulty + 1) % 3])
            }
            ui.button(CGRect(x: px + 196, y: by - 20, width: 140, height: 40), "Free-for-all", mouse: mouse) { [unowned self] in
                self.send(["t": "preset", "mode": "ffa"])
            }
            for (k, n) in [2, 3, 4].enumerated() {
                ui.button(CGRect(x: px + 352 + CGFloat(k) * 92, y: by - 20, width: 84, height: 40), "\(n) teams", mouse: mouse) { [unowned self] in
                    self.send(["t": "preset", "mode": "teams", "count": n])
                }
            }
            ui.button(CGRect(x: px + pw - 200, y: by - 20, width: 200, height: 40), "Start Game", mouse: mouse, accent: true) { [unowned self] in
                self.error = ""
                self.send(["t": "start"])
            }
        } else {
            ui.button(CGRect(x: px + pw - 200, y: by - 20, width: 200, height: 40), ready ? "Not Ready" : "Ready", mouse: mouse,
                      accent: !ready) { [unowned self] in self.send(["t": "ready", "ready": !self.ready]) }
            ui.label("Waiting for the host to start the game", 14, Palette.dim, at: CGPoint(x: px, y: by))
            ui.label(mapLabel, 15, Palette.text, at: CGPoint(x: px, y: by - 54), font: Fonts.bold)
        }
        ui.button(CGRect(x: px + pw - 200, y: by - 74, width: 200, height: 40), "Leave", mouse: mouse) { [unowned self] in self.leave() }
        if !error.isEmpty { ui.label(error, 15, Palette.bad, at: CGPoint(x: 0, y: by - 118), font: Fonts.bold, align: .center) }
        let cy = by - 140
        ui.label("CHAT  (Return to type)", 11, Palette.dim, at: CGPoint(x: px, y: cy), font: Fonts.bold)
        for (j, (s, n, t)) in chatLog.enumerated() {
            ui.label("\(n): \(t)", 13, s >= 0 ? Team(rawValue: s).lightColor : Palette.text, at: CGPoint(x: px, y: cy - 20 - CGFloat(j) * 18))
        }
        if let text = chatText {
            ui.label("Say: \(text)_", 14, Palette.text, at: CGPoint(x: px, y: cy - 26 - CGFloat(chatLog.count) * 18), font: Fonts.demi)
        }
    }

    override func mouseDown(with event: NSEvent) {
        _ = ui.click(event.location(in: self))
    }

    override func keyDown(with event: NSEvent) {
        if let text = chatText {
            switch event.keyCode {
            case 36, 76:
                let t = text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { send(["t": "chat", "text": t]) }
                chatText = nil
            case 53: chatText = nil
            case 51: chatText = String(text.dropLast())
            default:
                if let c = event.characters, c.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 }) {
                    chatText = String((text + c).prefix(120))
                }
            }
        } else if event.keyCode == 53 {
            leave()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            chatText = ""
        }
        draw(mouse: mouseLocation(in: self))
    }
}
