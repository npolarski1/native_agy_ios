import SwiftUI
import WidgetKit

@main
struct AntigravityWidgetsBundle: WidgetBundle {
    var body: some Widget {
        AntigravityStatusWidget()
        #if canImport(ActivityKit)
        AntigravityLiveActivity()
        #endif
    }
}
