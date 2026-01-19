import Cocoa
import SwiftUI
import Combine
import CoreGraphics

// MARK: - PLACEMENT SLOT MODEL
struct PlacementSlot: Identifiable, Equatable {
    let id: String
    let screenID: String
    let screenName: String
    let position: String
    let frame: NSRect
    let screenObject: NSScreen
    
    var debugDescription: String {
        "[\(screenName) (\(position))]: Origin:(\(Int(frame.origin.x)), \(Int(frame.origin.y))) Size:(\(Int(frame.width))x\(Int(frame.height)))"
    }
    
    static func == (lhs: PlacementSlot, rhs: PlacementSlot) -> Bool {
        return lhs.id == rhs.id && lhs.frame == rhs.frame
    }
}

@MainActor
class AppCoordinator: NSObject, ObservableObject {
    let feedManager: FeedManager
    
    private var tickerWindow: HardLockWindow?
    private var settingsWindow: NSWindow?
    private var isLayoutInProgress = false
    
    @Published var isMiniMode: Bool = false
    @Published var availableSlots: [PlacementSlot] = []
    
    // MARK: - PREFERENCES
    @Published var tickerPositionString: String {
        didSet {
            UserDefaults.standard.set(tickerPositionString, forKey: "tickerPosition")
            applyLayoutSafe()
        }
    }
    
    @Published var tickerSize: Int {
        didSet {
            UserDefaults.standard.set(tickerSize, forKey: "tickerSize")
            generatePlacementMap()
            applyLayoutSafe()
        }
    }
    
    @Published var preferredMonitorName: String {
        didSet {
            UserDefaults.standard.set(preferredMonitorName, forKey: "preferredMonitor")
            applyLayoutSafe()
        }
    }
    
    @Published var alwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop")
            tickerWindow?.level = alwaysOnTop ? .floating : .normal
        }
    }
    
    @Published var showAdminAtStartup: Bool {
        didSet {
            UserDefaults.standard.set(showAdminAtStartup, forKey: "showAdminAtStartup")
        }
    }
    
    init(feedManager: FeedManager) {
        self.feedManager = feedManager
        
        let defaults = UserDefaults.standard
        self.tickerPositionString = defaults.string(forKey: "tickerPosition") ?? "bottom"
        let size = defaults.integer(forKey: "tickerSize")
        self.tickerSize = size == 0 ? 1 : size
        self.preferredMonitorName = defaults.string(forKey: "preferredMonitor") ?? ""
        self.alwaysOnTop = defaults.object(forKey: "alwaysOnTop") as? Bool ?? true
        self.showAdminAtStartup = defaults.object(forKey: "showAdminAtStartup") as? Bool ?? true
        
        super.init()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    func start() {
        generatePlacementMap()
        ensureWindowExists()
        applyLayoutSafe()
        
        if UserDefaults.standard.bool(forKey: "hasLaunchedBefore") == false || showAdminAtStartup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.openSettings()
            }
        }
        
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
    }
    
    @objc private func screenConfigChanged() {
        if !isLayoutInProgress {
            generatePlacementMap()
            applyLayoutSafe()
        }
    }
    
    private func applyLayoutSafe() {
        DispatchQueue.main.async { [weak self] in
            self?.performLayout()
        }
    }
    
    // MARK: - MAP GENERATION
    private func generatePlacementMap() {
        var slots: [PlacementSlot] = []
        let screens = NSScreen.screens
        let height = heightForSize(tickerSize)
        
        for screen in screens {
            let id = String(getScreenID(screen))
            let name = screen.localizedName
            let visible = screen.visibleFrame
            
            let bottomFrame = NSRect(x: visible.origin.x, y: visible.minY, width: visible.width, height: height)
            let bottomSlot = PlacementSlot(id: "\(id)-bottom", screenID: id, screenName: name, position: "Bottom", frame: bottomFrame, screenObject: screen)
            slots.append(bottomSlot)
            
            let topFrame = NSRect(x: visible.origin.x, y: visible.maxY - height, width: visible.width, height: height)
            let topSlot = PlacementSlot(id: "\(id)-top", screenID: id, screenName: name, position: "Top", frame: topFrame, screenObject: screen)
            slots.append(topSlot)
        }
        self.availableSlots = slots
    }
    
    // MARK: - WINDOW MANAGEMENT
    
    private func ensureWindowExists() {
        if tickerWindow != nil { return }
        
        let window = HardLockWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = alwaysOnTop ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.isRestorable = false
        window.setFrameAutosaveName("")
        
        self.tickerWindow = window
        configureContentView(for: window)
    }
    
    private func configureContentView(for window: NSWindow) {
        // ✅ FIX: The view is created once and observes 'coordinator'
        // SwiftUICore handles the layout within the frame we provide via the window.
        let rootView = TickerView(feedManager: feedManager, coordinator: self)
            .edgesIgnoringSafeArea(.all)
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        
        window.contentView = hostingView
        // Allow the hosting view to expand with the window frame automatically
        hostingView.autoresizingMask = [.width, .height]
    }
    
    private func performLayout() {
        if isLayoutInProgress { return }
        isLayoutInProgress = true
        
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isLayoutInProgress = false
            }
        }
        
        ensureWindowExists()
        guard let window = tickerWindow else { return }
        
        // ✅ FIX: Safe unwrapping of slots and screens
        guard let slot = getCurrentTargetSlot() ?? availableSlots.first else {
            return // No screens available yet
        }
        
        // ✅ FIX: Stop re-assigning contentView.
        // Simply update the window frame. The NSHostingView with .width/.height autoresizing
        // will adjust the SwiftUI view automatically.
        window.targetFrame = slot.frame
        window.setFrame(slot.frame, display: true, animate: false)
        
        if !window.isVisible {
            window.orderFront(nil)
        }
        
        snapSettingsToTicker()
    }
    
    private func snapSettingsToTicker() {
        guard let win = settingsWindow, win.isVisible else { return }
        
        // Priority: Current Ticker Screen -> Target Screen Setting -> Main Screen
        let targetScreen = tickerWindow?.screen ?? NSScreen.screens.first { screen in
            String(getScreenID(screen)) == preferredMonitorName
        } ?? NSScreen.main
        
        if let screen = targetScreen {
            centerWindow(win, on: screen)
        }
    }
    
    private func centerWindow(_ window: NSWindow, on screen: NSScreen) {
        let screenFrame = screen.visibleFrame
        let newX = screenFrame.midX - (window.frame.width / 2)
        let newY = screenFrame.midY - (window.frame.height / 2)
        
        window.setFrameOrigin(NSPoint(x: newX, y: newY))
    }
    
    // MARK: - ADMIN UI HELPERS
    func openSettings() {
        if let win = settingsWindow {
            snapSettingsToTicker()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let w: CGFloat = 800
        let h: CGFloat = 650
        let window = createBaseWindow(width: w, height: h)
        
        let settingsView = SettingsView(feedManager: self.feedManager, coordinator: self)
        window.contentView = NSHostingView(rootView: settingsView)
        self.settingsWindow = window
        
        snapSettingsToTicker()
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeSettings() { settingsWindow?.close() }
    func showTicker() { applyLayoutSafe() }
    
    // MARK: - PRIVATE HELPERS
    private func getCurrentTargetSlot() -> PlacementSlot? {
        let prefID = preferredMonitorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefPos = tickerPositionString.lowercased()
        
        var targetSlot: PlacementSlot?
        if !prefID.isEmpty {
            targetSlot = availableSlots.first { $0.screenID == prefID && $0.position.lowercased() == prefPos }
        }
        if targetSlot == nil, let mainScreen = NSScreen.main {
            let mainID = String(getScreenID(mainScreen))
            targetSlot = availableSlots.first { $0.screenID == mainID && $0.position.lowercased() == prefPos }
        }
        return targetSlot ?? availableSlots.first
    }
    
    private func heightForSize(_ size: Int) -> CGFloat {
        size == 1 ? 48 : (size == 4 ? 108 : 72)
    }
    
    private func getScreenID(_ screen: NSScreen) -> UInt32 {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 0 }
        return id.uint32Value
    }
    
    private func createBaseWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        return window
    }
}

enum TickerPosition: String { case top, bottom }

// MARK: - THE HARD LOCK WINDOW
class HardLockWindow: NSWindow {
    var targetFrame: NSRect?
    
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
        if let target = targetFrame {
            let posChanged = abs(frameRect.origin.x - target.origin.x) > 2 || abs(frameRect.origin.y - target.origin.y) > 2
            let sizeChanged = abs(frameRect.width - target.width) > 2 || abs(frameRect.height - target.height) > 2
            
            if posChanged || sizeChanged {
                super.setFrame(target, display: displayFlag)
                return
            }
        }
        super.setFrame(frameRect, display: displayFlag)
    }
    
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if let target = targetFrame { return target }
        return frameRect
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
