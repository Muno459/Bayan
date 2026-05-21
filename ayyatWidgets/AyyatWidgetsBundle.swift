import WidgetKit
import SwiftUI

/// Registers every ayyat home-screen widget in one bundle.
@main
struct AyyatWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DailyAyahWidget()
        StreakWidget()
        GoalProgressWidget()
    }
}
