import SwiftUI

@main
struct FeedBarApp: App {
    init() {
        // Early app-level startup marker; runs before AppDelegate.applicationDidFinishLaunching
        AppLog.info("FEEDBARAPP init (pid:\(ProcessInfo.processInfo.processIdentifier))")
    }
    // We bind the AppDelegate here to handle startup logic
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // We leave this empty because AppCoordinator handles all windows manually.
        // This prevents SwiftUI from creating a default, unwanted window.
        Settings {
            EmptyView()
        }
    }
    // Function to calculate the sum of two numbers
    func sum(_ a: Int, _ b: Int) -> Int {
        return a + b
    }
}

// The Bridge between macOS System Events and our Coordinator
class AppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: AppCoordinator?
    
    // 1. Initialize the FeedManager here so it lives as long as the app does
    let feedManager = FeedManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 2. Pass the feedManager into the Coordinator
        let coordinator = AppCoordinator(feedManager: feedManager)
        self.coordinator = coordinator
        
        // Start the App (Splash or Ticker)
        coordinator.start()
        
        //Healthcheck after 5 mins
        Task { @MainActor in
            // run 5 mins after launch (or change delay)
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            feedManager.runHealthCheckNow()
        }
    }
    
    // Ensure the app stays running even if all windows close (it's a utility)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
