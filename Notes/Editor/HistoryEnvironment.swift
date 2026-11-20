import SwiftUI
import NotesCore

extension EnvironmentValues {
    /// Records and reads local note versions (Spec 02, S1 to S4). Nil if the history store could not open,
    /// in which case the app works as normal without version history.
    @Entry var history: HistoryRecorder? = nil
}
