import SwiftUI
import AppKit

class TickerWindow: NSPanel {
    init(contentRect: NSRect, content: () -> some View) {
        // 1. POSITIONING: Above Dock
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = screen.visibleFrame // Excludes Dock/Menu Bar
        
        let tickerHeight: CGFloat = 48
        let frame = NSRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY, // Bottom of usable screen area
            width: visibleFrame.width,
            height: tickerHeight
        )
        
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .hudWindow, .borderless],
            backing: .buffered,
            defer: false
        )
        
        // 2. LAYERING: Floating on top
        self.level = .mainMenu
        
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.isMovable = false
        
        self.contentView = NSHostingView(rootView: content())
        self.setFrame(frame, display: true)
    }
    
    // Allow interactions
    override var canBecomeKey: Bool { true }
}
