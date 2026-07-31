import SwiftUI

@main
struct AbundanceSampleApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(env.device)
                .environment(env.library)
                .abundanceTheme(.dark)
                .preferredColorScheme(.dark)
        }
    }
}

/// Composition root: the device store (everything `AbundanceDeviceKit`) and
/// the phone-side library, wired so every offloaded segment shows up in the
/// library as soon as it lands.
@MainActor
@Observable
final class AppEnvironment {
    let device: DeviceStore
    let library: LocalLibraryStore

    init() {
        self.device = DeviceStore()
        self.library = LocalLibraryStore()

        let library = library
        device.downloads.onSaved = { library.refresh() }
    }
}
