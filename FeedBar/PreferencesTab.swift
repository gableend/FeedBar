import SwiftUI

struct PreferencesTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var feedManager: FeedManager
    
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @State private var localScrollSpeed: Double = 1.0
    @AppStorage("tickerOpacity") private var tickerOpacity = 1.0
    @State private var localTickerOpacity: Double = 1.0
    @AppStorage("weatherCity") private var weatherCity = "Dublin"
    @State private var cityInput = ""
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes: Int = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ConfigSection(title: "RUN CONTROL") {
                    ConfigRow(label: "Refresh interval") {
                        Picker("", selection: $refreshIntervalMinutes) {
                            Text("5 min").tag(5); Text("10 min").tag(10); Text("15 min").tag(15); Text("30 min").tag(30); Text("60 min").tag(60)
                        }.labelsHidden().pickerStyle(.menu).frame(minWidth: 150)
                            .onChange(of: refreshIntervalMinutes) { _, newVal in
                                self.feedManager.startAutoRefresh(interval: TimeInterval(newVal * 60))
                            }
                    }
                    ConfigRow(label: "Refresh now") {
                        Button(action: { self.feedManager.hardRefresh() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                Text("REFRESH NOW").font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.black).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(FeedsTheme.utility).cornerRadius(6)
                        }.buttonStyle(.plain)
                    }
                }
                
                ConfigSection(title: "DISPLAY GEOMETRY") {
                    ConfigRow(label: "Target Monitor") {
                        Picker("", selection: $coordinator.preferredMonitorName) {
                            ForEach(NSScreen.screens, id: \.localizedName) { screen in
                                let idNum = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                                Text(screen.localizedName).tag(String(idNum))
                            }
                        }.labelsHidden().pickerStyle(.menu).frame(minWidth: 150)
                    }
                    ConfigRow(label: "Feed Bar Placement") {
                        CustomSegmentedControl(options: ["Bottom", "Top"], selection: Binding(get: { coordinator.tickerPositionString == "top" ? "Top" : "Bottom" }, set: { coordinator.tickerPositionString = ($0 == "Bottom" ? "bottom" : "top") }))
                    }
                    ConfigRow(label: "Feed Bar Size") {
                        CustomSegmentedControl(options: ["Compact", "Standard", "Large"], selection: Binding(get: { coordinator.tickerSize == 1 ? "Compact" : (coordinator.tickerSize == 2 ? "Standard" : "Large") }, set: { coordinator.tickerSize = ($0 == "Compact" ? 1 : ($0 == "Standard" ? 2 : 4)) }))
                    }
                    ConfigRow(label: "Always on top") {
                        Toggle("", isOn: $coordinator.alwaysOnTop).labelsHidden().toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                    }
                    ConfigRow(label: "Background Opacity") {
                        HStack {
                            Text("0%").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                            Slider(value: $localTickerOpacity, in: 0.0...1.0) { editing in
                                if !editing { tickerOpacity = localTickerOpacity }
                            }.tint(FeedsTheme.utility)
                            Text("100%").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                        }.frame(width: 200).onAppear { localTickerOpacity = tickerOpacity }
                    }
                }

                ConfigSection(title: "STREAM KINETICS") {
                    ConfigRow(label: "Flow Speed") {
                        HStack {
                            Text("Slow").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                            Slider(value: $localScrollSpeed, in: 0.5...20.0) { editing in
                                if !editing { scrollSpeed = localScrollSpeed }
                            }.tint(FeedsTheme.utility)
                            Text("Fast").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                        }.frame(width: 200).onAppear { localScrollSpeed = scrollSpeed }
                    }
                }
            }.padding(30)
        }
    }
}
