import SwiftUI

@main
struct SignstrMacApp: App {
    var body: some Scene {
        Window("Signstr", id: "main") {
            MacRootView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 920, height: 640)
    }
}
