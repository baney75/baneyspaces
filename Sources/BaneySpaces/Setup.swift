import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// Live state for the setup window, re-read every second while it's open.
final class SetupModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    @Published var modifier = Modifier.current
    @Published var conflicts: [String] = SystemShortcuts.conflicts(for: Modifier.current)
    @Published var desktops = Desktops.count
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    var onModifierChange: ((Modifier) -> Void)?
    private var timer: Timer?

    func startWatching() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
    }

    func stopWatching() { timer?.invalidate() }

    func reload() {
        trusted = AXIsProcessTrusted()
        conflicts = SystemShortcuts.conflicts(for: modifier)
        desktops = Desktops.count
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func pick(_ m: Modifier) {
        modifier = m
        Modifier.current = m
        onModifierChange?(m)
        reload()
    }

    func freeShortcuts() {
        SystemShortcuts.free(for: modifier)
        reload()
    }

    func setOpenAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        reload()
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BaneySpaces").font(.title2.bold())
                    Text("Nine workspaces. One row of keys.").foregroundStyle(.secondary)
                }
            }

            step(done: model.trusted, title: "Let BaneySpaces arrange windows") {
                if model.trusted {
                    Text("Allowed.").foregroundStyle(.secondary)
                } else {
                    Text("macOS asks before any app can show and hide other apps' windows. Turn on BaneySpaces in the list, and this updates on its own.")
                        .foregroundStyle(.secondary)
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }

            step(done: model.conflicts.isEmpty, title: "Pick your keys") {
                Picker("", selection: Binding(get: { model.modifier }, set: { model.pick($0) })) {
                    ForEach(Modifier.allCases) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("\(model.modifier.symbol)1 – \(model.modifier.symbol)9").monospaced(); Text("go to a workspace") }
                    GridRow { Text("\(model.modifier.symbol)⇧1 – \(model.modifier.symbol)⇧9").monospaced(); Text("send the front window there") }
                }
                Text(model.modifier.tradeoff).font(.callout).foregroundStyle(.secondary)
                ForEach(model.conflicts, id: \.self) { c in
                    HStack {
                        Text(c).font(.callout)
                        Spacer()
                        Button("Free Them") { model.freeShortcuts() }
                    }
                }
            }

            step(done: model.desktops <= 1, title: "Keep one macOS desktop") {
                if model.desktops <= 1 {
                    Text("Every window stays within reach of the nine workspaces.").foregroundStyle(.secondary)
                } else {
                    Text("You have \(model.desktops) desktops in Mission Control. Windows on the others are out of reach. Open Mission Control, hover each extra desktop at the top, and click its ✕.")
                        .foregroundStyle(.secondary)
                    Button("Open Mission Control") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
                    }
                }
            }

            step(done: model.openAtLogin, title: "Start with your Mac") {
                Toggle("Open BaneySpaces at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            }

            Divider()
            HStack {
                Text("Full screen fills the screen here, so every window stays on a workspace. Change anything later from the menu bar icon.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func step<Content: View>(done: Bool, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let model = SetupModel()

    convenience init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.init(window: window)
        window.title = "Set Up BaneySpaces"
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(model: model) { [weak window] in window?.close() })
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
    }

    func show() {
        model.reload()
        model.startWatching()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { model.stopWatching() }
}
