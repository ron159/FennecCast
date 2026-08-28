import SwiftUI

struct RootView: View {
  let environment: AppEnvironment

  var body: some View {
    NavigationStack {
      Group {
        if environment.startupFailure == nil {
          ContentUnavailableView {
            Label {
              Text(LocalizedStringKey(environment.appName))
            } icon: {
              Image(systemName: "headphones")
            }
          } description: {
            Text("foundation.status")
          }
        } else {
          ContentUnavailableView {
            Label("startup.database.title", systemImage: "externaldrive.badge.exclamationmark")
          } description: {
            Text("startup.database.message")
          }
        }
      }
      .navigationTitle(Text(LocalizedStringKey(environment.appName)))
    }
  }
}
