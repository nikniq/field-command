import AppKit
import SpriteKit

/// SKView that explicitly routes every input event to the current scene.
final class GameView: SKView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { scene?.keyDown(with: event) }
    override func keyUp(with event: NSEvent) { scene?.keyUp(with: event) }
    override func mouseDown(with event: NSEvent) { scene?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { scene?.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { scene?.mouseDragged(with: event) }
    override func rightMouseDown(with event: NSEvent) { scene?.rightMouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { scene?.rightMouseUp(with: event) }
    override func scrollWheel(with event: NSEvent) { scene?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { scene?.magnify(with: event) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var gameView: GameView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let frame = NSRect(x: 0, y: 0, width: 1400, height: 880)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Field Command"
        window.minSize = NSSize(width: 1100, height: 700)
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true

        gameView = GameView(frame: frame)
        // Siblings draw in the order they were added. With this true, SpriteKit draws same-z siblings in an
        // undefined order: labels went under their buttons and card icons under their plates, some frames.
        gameView.ignoresSiblingOrder = false
        gameView.preferredFramesPerSecond = 60
        window.contentView = gameView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(gameView)
        if let d = Debug.autostart {
            gameView.presentScene(GameScene(size: frame.size, difficulty: d))
        } else {
            gameView.presentScene(MenuScene(size: frame.size))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newGame(_ sender: Any?) {
        guard let v = gameView else { return }
        v.presentScene(MenuScene(size: v.bounds.size), transition: .fade(withDuration: 0.4))
    }

    @objc func toggleFPS(_ sender: Any?) {
        gameView.showsFPS.toggle()
        gameView.showsNodeCount = gameView.showsFPS
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Field Command", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Field Command", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Field Command", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let gameItem = NSMenuItem()
        main.addItem(gameItem)
        let gameMenu = NSMenu(title: "Game")
        let newItem = NSMenuItem(title: "New Game…", action: #selector(newGame(_:)), keyEquivalent: "n")
        newItem.target = self
        gameMenu.addItem(newItem)
        gameItem.submenu = gameMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fs)
        let fps = NSMenuItem(title: "Show FPS", action: #selector(toggleFPS(_:)), keyEquivalent: "")
        fps.target = self
        viewMenu.addItem(fps)
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
if let m = Debug.env["FC_SKIRMISHTEST"] {
    Debug.runSkirmishTest(m)
}
if Debug.env["FC_REPLAYTEST"] != nil {
    Debug.runReplayTest()
}
if Debug.env["FC_CAMPAIGNTEST"] != nil {
    Debug.runCampaignTest()
}
if Debug.env["FC_CRATETEST"] != nil {
    Debug.runCrateTest()
}
if Debug.env["FC_HIGHTEST"] != nil {
    Debug.runHighGroundTest()
}
if Debug.env["FC_POLISHTEST"] != nil {
    Debug.runPolishTest()
}
if Debug.env["FC_WALLTEST"] != nil {
    Debug.runWallTest()
}
if Debug.env["FC_AIRTEST"] != nil {
    Debug.runAirTest()
}
if Debug.env["FC_MODETEST"] != nil {
    Debug.runModeTest()
}
if Debug.env["FC_STARTTEST"] != nil {
    Debug.runStartTest()
}
if Debug.env["FC_ABILITYTEST"] != nil {
    Debug.runAbilityTest()
}
if Debug.env["FC_COUNTERTEST"] != nil {
    Debug.runCounterTest()
}
if Debug.env["FC_ICONSOAK"] != nil {
    Debug.runIconSoak()
}
if Debug.env["FC_ARTYTEST"] != nil {
    Debug.runArtilleryTest()
}
if Debug.env["FC_PINGTEST"] != nil {
    Debug.runPingTest()
}
if Debug.env["FC_MEDICTEST"] != nil {
    Debug.runMedicTest()
}
if Debug.env["FC_SAVETEST"] != nil {
    Debug.runSaveTest()
}
if Debug.env["FC_AUDIOTEST"] != nil {
    Debug.runAudioTest()
}
if Debug.env["FC_AITEST"] != nil {
    Debug.runAITest()
}
if Debug.env["FC_STORETEST"] != nil {
    Debug.runStoreTest()
}
if let dir = Debug.env["FC_CARDSHOT"] {
    Debug.runCardShot(dir)
}
if Debug.env["FC_TOWERTEST"] != nil {
    Debug.runTowerTest()
}
if Debug.env["FC_UPGRADETEST"] != nil {
    Debug.runUpgradeTest()
}
if Debug.env["FC_SIEGETEST"] != nil {
    Debug.runSiegeTest()
}
if Debug.env["FC_TEAMSTEST"] != nil {
    Debug.runTeamsTest()
}
if Debug.env["FC_REPAIRTEST"] != nil {
    Debug.runRepairTest()
}
if let m = Debug.env["FC_BRIDGETEST"] {
    Debug.runBridgeTest(m)
}
if Debug.env["FC_WORLDTEST"] != nil {
    Debug.runWorldTest()
}
if Debug.env["FC_HOSTTEST"] != nil {
    Debug.runHostTest()
    exit(0)
}
if CommandLine.arguments.contains("--server") {
    // Dedicated server: FieldCommand --server [--port 47777] [--name NAME]
    let args = CommandLine.arguments
    func opt(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let server = GameServer(name: opt("--name") ?? "Field Command server", port: opt("--port").flatMap(UInt16.init) ?? NetProtocol.gamePort)
    server.simSpeed = max(1, Int(Debug.env["FC_SIMSPEED"] ?? "") ?? 1)
    do {
        try server.start()
    } catch {
        print(error.localizedDescription)
        exit(1)
    }
    print("Dedicated server running. LAN discovery on UDP \(NetProtocol.discoveryPort). Ctrl+C to stop.")
    while true { sleep(60) }
}
if let address = Debug.env["FC_NETTEST"] {
    Debug.runNetTest(address)
    exit(0)
}
if let path = Debug.env["FC_MENUSHOT"] {
    Debug.menuShot(path)
    exit(0)
}
if Debug.headless {
    Debug.runHeadless()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
