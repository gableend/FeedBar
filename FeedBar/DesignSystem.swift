import SwiftUI

// MARK: - THEME EXTENSIONS
// These define your specific brand colors globally.
extension FeedsTheme {
    static let surface = Color(hex: "16181D")
    static let inputBackground = Color(hex: "000000").opacity(0.4)
    static let success = Color(hex: "34C759")
    static let newsHighContrast = Color(hex: "7E8BA8")
}

// MARK: - WINDOW ACCESSOR
// Safely accesses the NSWindow for centering and styling.
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.callback(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - TOGGLE STYLES
struct SignalSwitchStyle: ToggleStyle {
    var onColor: Color = FeedsTheme.ai
    var offColor: Color = Color.white.opacity(0.15)
    var knobColor: Color = .white
    var width: CGFloat = 36
    var height: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? onColor : offColor)
                    .frame(width: width, height: height)
                    .overlay(Capsule().stroke(FeedsTheme.divider.opacity(0.8), lineWidth: 1))
                Circle()
                    .fill(knobColor)
                    .frame(width: height - 4, height: height - 4)
                    .padding(2)
                    .shadow(radius: 1)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isOn ? FeedsTheme.ai : FeedsTheme.secondaryText)
                .onTapGesture { configuration.isOn.toggle() }
            configuration.label
        }
    }
}

// MARK: - LAYOUT CONTAINERS
struct ConfigSection<Content: View>: View {
    let title: String
    let content: Content
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(FeedsTheme.ai)
            VStack(spacing: 0) { content }.padding(1).background(FeedsTheme.divider).cornerRadius(6)
        }
    }
}

struct ConfigRow<Content: View>: View {
    let label: String
    let content: Content
    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(FeedsTheme.primaryText).frame(width: 160, alignment: .leading)
            content
            Spacer()
        }.padding(14).background(FeedsTheme.surface)
    }
}

// MARK: - SHARED UI COMPONENTS
struct SignalIconTileView: View {
    let domain: String?
    let fallbackSystemIcon: String
    let tint: Color
    let size: CGFloat
    let tileSize: CGFloat
    @ObservedObject var faviconStore: FaviconStore
    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(FeedsTheme.inputBackground)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(FeedsTheme.divider.opacity(0.7), lineWidth: 1))

            if let domain, let img = faviconStore.image(for: domain, size: 64) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.16)).frame(width: size + 8, height: size + 8)
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .grayscale(1.0)
                        .opacity(0.95)
                }
            } else {
                Image(systemName: fallbackSystemIcon)
                    .font(.system(size: size, weight: .bold))
                    .foregroundColor(tint)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct DataRow: View {
    let name: String
    @Binding var isEnabled: Bool
    let isPersonal: Bool
    let isNew: Bool
    let itemCount: Int
    let onDelete: (() -> Void)?
    
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 13, weight: .medium))
                    .foregroundColor(isEnabled ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                if isPersonal { Circle().fill(FeedsTheme.ai).frame(width: 5, height: 5).padding(.top, 2) }
            }.frame(width: 240, alignment: .leading)

            if isNew {
                Text("NEW").font(.system(size: 8, weight: .black)).padding(3)
                    .background(FeedsTheme.success).foregroundColor(.black).cornerRadius(2)
            }

            Spacer()

            Text("\(itemCount)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(itemCount > 0 ? FeedsTheme.secondaryText : .red.opacity(0.6))
                .frame(width: 30, alignment: .trailing)
                .padding(.trailing, 4)

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                .frame(width: 44)

            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isHovering ? .red : FeedsTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .frame(width: 20)
            } else {
                Spacer().frame(width: 20)
            }
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 10)
        .background(isNew ? FeedsTheme.success.opacity(0.1) : (isHovering ? FeedsTheme.divider.opacity(0.3) : Color.clear))
        .onHover { isHovering = $0 }
    }
}

// MARK: - SIDEBAR BUTTON
struct SidebarButton: View {
    let title, icon: String; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Rectangle().fill(isSelected ? FeedsTheme.ai : Color.clear).frame(width: 3)
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(isSelected ? FeedsTheme.primaryText : FeedsTheme.secondaryText).frame(width: 24)
                Text(title.uppercased()).font(.system(size: 11, weight: isSelected ? .bold : .medium)).foregroundColor(isSelected ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                Spacer()
            }.frame(height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain).background(isSelected ? FeedsTheme.divider.opacity(0.3) : Color.clear)
    }
}

// MARK: - ABOUT VIEW
struct AboutView: View {
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 40)).foregroundColor(FeedsTheme.ai)
            Text("FEEDS").font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundColor(FeedsTheme.primaryText)
            Text("Signal Layer v1.0").font(.caption).foregroundColor(FeedsTheme.secondaryText)
            VStack(spacing: 5) {
                Text("feeds.bar").font(.system(size: 13, weight: .bold)).foregroundColor(FeedsTheme.primaryText)
                Text("hello@feeds.bar").font(.system(size: 12)).foregroundColor(FeedsTheme.secondaryText)
            }.padding(.top, 10)
        }
    }
}
// MARK: - CUSTOM SEGMENTED CONTROL
struct CustomSegmentedControl: View {
    let options: [String]; @Binding var selection: String
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button(action: { selection = option }) {
                    Text(option).font(.system(size: 11, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? .black : FeedsTheme.primaryText)
                        .padding(.vertical, 5).padding(.horizontal, 12)
                        .background(isSelected ? FeedsTheme.primaryText : Color.clear)
                        .cornerRadius(4)
                }.buttonStyle(.plain)
            }
        }.padding(2).background(FeedsTheme.inputBackground).cornerRadius(6)
    }
}
