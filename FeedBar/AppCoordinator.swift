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
        
        var initialMonitor = defaults.string(forKey: "preferredMonitor") ?? ""
        // If there's no stored preference, default to the main screen's numeric id if available
        if initialMonitor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let main = NSScreen.main, let num = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                initialMonitor = String(num.uint32Value)
            }
        }
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
    
    func openSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // 1. Updated Dimensions to match SettingsView (800x650)
        let w: CGFloat = 800
        let h: CGFloat = 650
        let window = createBaseWindow(width: w, height: h)
        
        // Smart Positioning: Find screen with mouse and center mathematically
        let mouseLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) {
            let screenFrame = screen.visibleFrame
            // Calculate center point based on visible frame (respecting Dock/Menu Bar)
            let x = screenFrame.midX - (w / 2)
            let y = screenFrame.midY - (h / 2)
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
                styleMask: [.nonactivatingPanel, .hudWindow, .borderless],
                backing: .buffered, defer: false
            )
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = alwaysOnTop ? (.mainMenu + 1) : .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.isMovableByWindowBackground = false
            panel.isMovable = false

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
        var targetScreen: NSScreen?
        let prefRaw = preferredMonitorName.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Try numeric display ID match first
        if let idNum = UInt32(prefRaw) {
            targetScreen = screens.first(where: { scr in
                if let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    return num.uint32Value == idNum
                }
                return false
            })
        }

        // 2) If still not found and pref empty, choose the screen under the mouse
        if targetScreen == nil && prefRaw.isEmpty {
            let mouseLoc = NSEvent.mouseLocation
            targetScreen = screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        }

        // 3) If pref suggests built-in/internal, map to main screen
        if targetScreen == nil && !prefRaw.isEmpty {
            let loweredPref = prefRaw.lowercased()
            if ["built", "retina", "internal", "builtin", "laptop", "built-in"].contains(where: { loweredPref.contains($0) }) {
                targetScreen = NSScreen.main
            }
        }

        // 4) Fuzzy name matching fallback
        if targetScreen == nil && !prefRaw.isEmpty {
            let loweredPref = prefRaw.lowercased()
            let matches = screens.filter { screen in
                let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return name == loweredPref || name.contains(loweredPref) || loweredPref.contains(name)
            }
            if matches.count == 1 {
                targetScreen = matches.first
            } else if matches.count > 1 {
                let mouseLoc = NSEvent.mouseLocation
                targetScreen = matches.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? matches.first
            } else {
                targetScreen = screens.first(where: { $0.localizedName == prefRaw })
            }
        }

        if targetScreen == nil { targetScreen = NSScreen.main }
        guard let screen = targetScreen else { return }

        // Use the same height mapping as TickerView.heightForSize(_:) to avoid clipping
        let height: CGFloat = (tickerSize == 1 ? 48 : (tickerSize == 4 ? 108 : 72))

        // Use visibleFrame origin/width so we position inside the usable area (accounts for Dock/Menu Bar)
        let visibleFrame = screen.visibleFrame // Accounts for Dock/Menu Bar
        let x = visibleFrame.origin.x
        let width = visibleFrame.width
        var y: CGFloat = 0

        if tickerPositionString == "top" {
            // Sit directly below the menu bar
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
        // Center initially on main screen, but openSettings will override for mouse screen
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
