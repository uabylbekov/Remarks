import SwiftUI

/// Supplies a bounded viewport to the native scrolling surface. Content length cannot determine screen size.
/// The viewport reaches under the navigation bar, the home indicator and the keyboard, as a scroll view does, and the
/// surface turns the overlap into content insets, so text scrolls beneath them instead of being cut off at their edges.
struct EditorViewport<Surface: View>: View {
    @ViewBuilder var surface: Surface

    var body: some View {
        let viewport = surface
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        // The Mac window already lays its scroll view out under the toolbar.
        viewport.ignoresSafeArea()
        #else
        viewport
        #endif
    }
}
