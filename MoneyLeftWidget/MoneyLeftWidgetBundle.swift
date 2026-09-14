import WidgetKit
import SwiftUI

@main
struct MoneyLeftWidgetBundle: WidgetBundle {
    var body: some Widget {
        RemainingBudgetWidget()
        ExpenseLiveActivityWidget()
    }
}
