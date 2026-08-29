import SwiftUI

@main
struct SigneurMacApp: App {
    var body: some Scene {
        Window("Signeur", id: "main") {
            MacRootView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 920, height: 640)
    }
}
