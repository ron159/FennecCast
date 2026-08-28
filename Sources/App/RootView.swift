import SwiftUI

struct RootView: View {
  let environment: AppEnvironment

  var body: some View {
    NavigationStack {
      ContentUnavailableView(
        environment.appName,
        systemImage: "headphones",
        description: Text("Foundation ready")
      )
      .navigationTitle(environment.appName)
    }
  }
}
