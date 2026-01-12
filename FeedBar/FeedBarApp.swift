import SwiftUI

@main
struct FeedBarApp: App {
    // We bind the AppDelegate here to handle startup logic
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // We leave this empty because AppCoordinator handles all windows manually.
        // This prevents SwiftUI from creating a default, unwanted window.
        Settings {
            EmptyView()
        }
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
        feedManager.scheduleHealthCheck(after: 300) // 5 minutes
        
    }
    
    // Ensure the app stays running even if all windows close (it's a utility)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
