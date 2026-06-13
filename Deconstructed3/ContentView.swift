import DeconstructedFeature
import SwiftUI

/// The app's root view. The store, the 3-pane editor (tree | viewport | editable
/// inspector), and all open/edit/save behavior live in
/// `DeconstructedFeature.AppRootView`; this is just the app-target seam.
struct ContentView: View {
    var body: some View {
        AppRootView()
    }
}
