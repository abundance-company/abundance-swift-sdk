import SwiftUI
import UIKit

/// The main shell: Camera (live control), Recordings (phone library + camera
/// offload), Settings. Also owns the device event-stream subscription so
/// state, the recording timer, and auto-save work from any tab while the app
/// is active.
struct MainTabView: View {
    enum Tab: String { case camera, recordings, settings }

    @Environment(DeviceStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Tab = MainTabView.initialTab

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { CameraTabView() }
                .tabItem { Label("Camera", systemImage: "video.fill") }
                .tag(Tab.camera)

            NavigationStack { RecordingsView() }
                .tabItem { Label("Recordings", systemImage: "film.stack") }
                .tag(Tab.recordings)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(AbundanceTheme.dark.textAccentOcean)
        .onChange(of: scenePhase) { _, phase in
            // The SoftAP socket doesn't survive backgrounding anyway; reopen on
            // return instead of burning the radio while invisible.
            switch phase {
            case .active: store.open()
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                store.close()
            default: break
            }
        }
        .onChange(of: store.recordPhase, initial: true) { _, phase in
            // The device keeps capturing on its own, but auto-lock would kill
            // the viewfinder and the live status mid-take.
            UIApplication.shared.isIdleTimerDisabled = phase == .starting || phase == .recording
        }
        .task(id: store.isPaired) {
            if store.isPaired { store.open() }
        }
    }

    /// DEBUG-only: `-uiTab recordings|settings` opens on that tab so simulator
    /// smoke tests can screenshot screens simctl can't navigate to.
    private static var initialTab: Tab {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-uiTab"), i + 1 < args.count,
           let tab = Tab(rawValue: args[i + 1]) {
            return tab
        }
        #endif
        return .camera
    }
}
