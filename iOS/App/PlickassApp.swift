import AuthenticationServices
import SwiftUI

enum Brand {
  static let amber = Color(red: 245 / 255, green: 176 / 255, blue: 60 / 255)
  static let cream = Color(red: 250 / 255, green: 244 / 255, blue: 228 / 255)
  static let coal = Color(red: 38 / 255, green: 30 / 255, blue: 23 / 255)
  static let mint = Color(red: 126 / 255, green: 214 / 255, blue: 184 / 255)
}

@main struct PlickassApp: App {
  @StateObject private var account = AccountStore()
  @StateObject private var downloads = DownloadManager()

  init() {
    // Artwork thumbnails are cached between launches.
    URLCache.shared = URLCache(memoryCapacity: 40 << 20, diskCapacity: 300 << 20)
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(account)
        .environmentObject(downloads)
        .tint(Brand.amber)
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var downloads: DownloadManager
  @State private var tab = 0

  var body: some View {
    Group {
      if account.token == nil {
        SignInView()
      } else {
        TabView(selection: $tab) {
          LibraryView()
            .tabItem { Label("Library", systemImage: "square.stack") }.tag(0)
          DownloadsView()
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(1)
            .badge(downloads.pending)
          SettingsView()
            .tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
      }
    }
    .alert(
      "plickass", isPresented: Binding(get: { downloads.notice != nil }, set: { if !$0 { downloads.notice = nil } })
    ) {
      Button("OK") { downloads.notice = nil }
    } message: {
      Text(downloads.notice ?? "")
    }
  }
}

/// The wordmark: cream "plick", amber "ass".
struct Wordmark: View {
  var size: CGFloat = 44
  var body: some View {
    (Text("plick").foregroundStyle(Brand.cream) + Text("ass").foregroundStyle(Brand.amber))
      .font(.system(size: size, weight: .heavy, design: .rounded))
      .accessibilityLabel("plickass")
  }
}

struct SignInView: View {
  @EnvironmentObject private var account: AccountStore
  @Environment(\.webAuthenticationSession) private var session

  var body: some View {
    ZStack {
      LinearGradient(colors: [Brand.coal, .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
      VStack(spacing: 22) {
        Spacer()
        Image("Logo").resizable().scaledToFit().frame(width: 132, height: 132)
          .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
          .accessibilityHidden(true)
        Wordmark()
        Text("Your Plex music as real files: Artist / Album / 01 - Track, saved to Files.")
          .font(.title3).multilineTextAlignment(.center).foregroundStyle(Brand.cream.opacity(0.8))
          .padding(.horizontal, 28)
        Spacer()
        if let error = account.error {
          Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
        }
        Button {
          Task { await account.signIn(using: session) }
        } label: {
          HStack {
            if account.signingIn { ProgressView().tint(.black) }
            Text("Sign In with Plex").font(.headline)
          }
          .frame(maxWidth: 360).padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent).foregroundStyle(.black)
        .disabled(account.signingIn)
        .padding(.horizontal, 28)
        Text("plickass reads your library and downloads the files you choose. It never changes anything on your server. Not affiliated with Plex.")
          .font(.footnote).foregroundStyle(Brand.cream.opacity(0.55)).multilineTextAlignment(.center)
          .padding(.horizontal, 32).padding(.bottom, 24)
      }
    }
    .preferredColorScheme(.dark)
  }
}
