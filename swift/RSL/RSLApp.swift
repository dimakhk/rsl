import SwiftUI

/* Распознавание РЖЯ - the iOS app, written in Swift.

   Engine/  camera, the two recognisers, finding the person - no interface
   UI/      the screens, after the Figma mockup
   The same thing as the web app in the root of the repository, which remains
   the reference for how everything should look and behave. */

@main
struct RSLApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
