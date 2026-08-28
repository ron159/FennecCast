import SwiftUI

struct RootView: View {
  let environment: AppEnvironment

  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label {
          Text(LocalizedStringKey(environment.appName))
        } icon: {
          Image(systemName: "headphones")
        }
      } description: {
        Text("foundation.status")
      }
      .navigationTitle(Text(LocalizedStringKey(environment.appName)))
    }
  }
}
