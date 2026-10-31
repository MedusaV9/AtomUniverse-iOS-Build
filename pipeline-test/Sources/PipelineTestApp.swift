import SwiftUI

@main
struct PipelineTestApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("AtomUniverse")
                    .font(.largeTitle)
                Text("Pipeline-Test: unsignierte .ipa aus GitHub Actions. Das ist nicht das Spiel.")
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
