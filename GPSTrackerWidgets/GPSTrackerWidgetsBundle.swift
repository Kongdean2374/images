import WidgetKit
import SwiftUI

@main
struct GPSTrackerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StepsWidget()
        WorkoutLiveActivityWidget()
    }
}
