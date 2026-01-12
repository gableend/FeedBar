import Cocoa
import SwiftUI
import Combine

@MainActor
class AppCoordinator: NSObject, ObservableObject {
    // Dependencies
    let feedManager: FeedManager
    
    // Window References
    private var tickerWindow: NSPanel?
    private var settingsWindow: NSWindow?
    
    // MARK: - Preferences (Converted to @Published for Binding Support)
    
    @Published var tickerPositionString: String {
        didSet {
            UserDefaults.standard.set(tickerPositionString, forKey: "tickerPosition")
            updateSettings(position: TickerPosition(rawValue: tickerPositionString))
        }
    }
    
    @Published var tickerSize: Int {
        didSet {
            UserDefaults.standard.set(tickerSize, forKey: "tickerSize")
            updateSettings(size: tickerSize)
        }
    }
    
    @Published var preferredMonitorName: String {
        didSet {
            UserDefaults.standard.set(preferredMonitorName, forKey: "preferredMonitor")
            updateSettings(monitor: preferredMonitorName)
        }
    }
    
    @Published var alwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop")
            updateSettings(onTop: alwaysOnTop)
        }
    }
    
    @Published var showAdminAtStartup: Bool {
        didSet {
            UserDefaults.standard.set(showAdminAtStartup, forKey: "showAdminAtStartup")
        }
    }
    
    init(feedManager: FeedManager) {
        self.feedManager = feedManager
        
        // 1. Load values into local variables first to avoid 'self' access before super.init
        let defaults = UserDefaults.standard
        let initialPos = defaults.string(forKey: "tickerPosition") ?? "bottom"
        
        var initialSize = defaults.integer(forKey: "tickerSize")
        if initialSize == 0 { initialSize = 1 } // Default to size 1 if not set
        
        let initialMonitor = defaults.string(forKey: "preferredMonitor") ?? ""
        let initialOnTop = defaults.object(forKey: "alwaysOnTop") as? Bool ?? true
        let initialShowAdmin = defaults.object(forKey: "showAdminAtStartup") as? Bool ?? true
        
        // 2. Assign to properties
        self.tickerPositionString = initialPos
        self.tickerSize = initialSize
        self.preferredMonitorName = initialMonitor
        self.alwaysOnTop = initialOnTop
        self.showAdminAtStartup = initialShowAdmin
        
        super.init()
    }
    
    func start() {
        showTicker()
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore || showAdminAtStartup {
            openSettings()
        }
        if !hasLaunchedBefore { UserDefaults.standard.set(true, forKey: "hasLaunchedBefore") }
    }
    
    // MARK: - ADMIN DASHBOARD
    
    // Renamed to openSettings to match TickerView call site
    func openSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let window = createBaseWindow(width: 800, height: 550)
        
        // Smart Positioning: Find screen with mouse
        let mouseLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 400
            let y = screenFrame.midY - 275
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
        
        let settingsView = SettingsView(feedManager: self.feedManager, coordinator: self)
        window.contentView = NSHostingView(rootView: settingsView)
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeSettings() {
        settingsWindow?.close()
    }
    
    // MARK: - TICKER ENGINE
    func showTicker() {
        if tickerWindow == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = alwaysOnTop ? (.mainMenu + 1) : .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            
            let view = TickerView(feedManager: feedManager, coordinator: self)
            panel.contentView = NSHostingView(rootView: view)
            self.tickerWindow = panel
        }
        updateWindowPosition()
        tickerWindow?.orderFront(nil)
    }
    
    // MARK: - GEOMETRY
    func updateSettings(position: TickerPosition? = nil, size: Int? = nil, onTop: Bool? = nil, monitor: String? = nil) {
        DispatchQueue.main.async {
            if let onTop = onTop { self.tickerWindow?.level = onTop ? (.mainMenu + 1) : .normal }
            self.updateWindowPosition()
        }
    }
    
    private func updateWindowPosition() {
        guard let panel = tickerWindow else { return }
        
        let screens = NSScreen.screens
        var targetScreen = NSScreen.main
        if !preferredMonitorName.isEmpty, let preferred = screens.first(where: { $0.localizedName == preferredMonitorName }) {
            targetScreen = preferred
        }
        guard let screen = targetScreen else { return }
        
        let height: CGFloat = (tickerSize == 1 ? 32 : (tickerSize == 2 ? 48 : 80))
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame // Accounts for Dock/Menu Bar
        
        let x = screenFrame.origin.x
        let width = screenFrame.width
        var y: CGFloat = 0
        
        if tickerPositionString == "top" {
            // Sit BELOW the menu bar
            y = visibleFrame.maxY - height
        } else {
            // Sit ABOVE bottom safe area (Dock)
            y = visibleFrame.minY
        }
        
        let newFrame = NSRect(x: x, y: y, width: width, height: height)
        panel.setFrame(newFrame, display: true, animate: false)
    }
    
    private func createBaseWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.center()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        return window
    }
}

enum TickerPosition: String { case top, bottom }
