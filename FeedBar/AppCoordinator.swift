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
    
    // Custom HardLockWindow
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
        
        // Admin UI follows Ticker (Slight delay to ensure Ticker is placed first)
        if UserDefaults.standard.bool(forKey: "hasLaunchedBefore") == false || showAdminAtStartup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openSettings()
            }
        }
        if UserDefaults.standard.bool(forKey: "hasLaunchedBefore") == false {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
    }
    
    @objc private func screenConfigChanged() {
        // print("DEBUG: Screen config changed.")
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
        
        // print("--- SCREEN MAP ---")
        for screen in screens {
            let id = String(getScreenID(screen))
            let name = screen.localizedName
            let visible = screen.visibleFrame
            
            // Bottom
            let bottomFrame = NSRect(x: visible.origin.x, y: visible.minY, width: visible.width, height: height)
            let bottomSlot = PlacementSlot(id: "\(id)-bottom", screenID: id, screenName: name, position: "Bottom", frame: bottomFrame, screenObject: screen)
            slots.append(bottomSlot)
            
            // Top
            let topFrame = NSRect(x: visible.origin.x, y: visible.maxY - height, width: visible.width, height: height)
            let topSlot = PlacementSlot(id: "\(id)-top", screenID: id, screenName: name, position: "Top", frame: topFrame, screenObject: screen)
            slots.append(topSlot)
            
            // print("Slot: \(bottomSlot.debugDescription)")
        }
        // print("------------------")
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
        
        // Initial setup
        configureContentView(for: window)
    }
    
    // Setup content view with AutoLayout to ensure full edge-to-edge filling
    private func configureContentView(for window: NSWindow) {
        let rootView = TickerView(feedManager: feedManager, coordinator: self)
            .edgesIgnoringSafeArea(.all)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        
        window.contentView = hostingView
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
        
        // 1. Find Target Slot
        let slot = getCurrentTargetSlot() ?? availableSlots.first ?? PlacementSlot(id: "def", screenID: "0", screenName: "Unknown", position: "Bottom", frame: .zero, screenObject: NSScreen.main!)
        
        // print("DEBUG: LOCKED Target Frame -> \(slot.debugDescription)")
        
        // 2. RESIZE CONTENT VIEW (CRITICAL FIX FOR CLIPPPING)
        // We inject the EXACT WIDTH and force LEADING alignment.
        let sizedView = TickerView(feedManager: feedManager, coordinator: self)
            .edgesIgnoringSafeArea(.all)
            .frame(width: slot.frame.width, height: slot.frame.height, alignment: .leading)
            .id(UUID()) // Force redraw
        
        window.contentView = NSHostingView(rootView: sizedView)
        
        // 3. LOCK AND MOVE
        window.targetFrame = slot.frame
        window.setFrame(slot.frame, display: true, animate: false)
        window.orderFront(nil)
        
        // Move Settings Window if open
        snapSettingsToTicker()
    }
    
    private func snapSettingsToTicker() {
        guard let win = settingsWindow, win.isVisible else { return }
        
        // Priority 1: Use actual window location if possible
        if let tickerScreen = tickerWindow?.screen {
            centerWindow(win, on: tickerScreen)
        }
        // Priority 2: Use theoretical slot location
        else if let slot = getCurrentTargetSlot() {
            centerWindow(win, on: slot.screenObject)
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
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            snapSettingsToTicker()
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
    func updateSettings(position: TickerPosition? = nil, size: Int? = nil, onTop: Bool? = nil, monitor: String? = nil) {}
    
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
            // Check for BOTH Origin drift AND Size clamping
            let posChanged = abs(frameRect.origin.x - target.origin.x) > 5 || abs(frameRect.origin.y - target.origin.y) > 5
            let sizeChanged = abs(frameRect.width - target.width) > 5 || abs(frameRect.height - target.height) > 5
            
            if posChanged || sizeChanged {
                // Uncomment to see the OS fighting back
                // print("BLOCKED: System change to \(frameRect). Reseting to \(target)")
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
