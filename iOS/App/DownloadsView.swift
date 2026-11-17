import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
  @EnvironmentObject private var downloads: DownloadManager
  @Environment(\.openURL) private var openURL

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            if downloads.running {
              let total = downloads.jobs.count
              ProgressView(value: Double(total - downloads.pending), total: Double(max(1, total)))
              Text("\(total - downloads.pending) of \(total) · \(ByteCountFormatter.string(fromByteCount: downloads.bytesSaved, countStyle: .file))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if downloads.jobs.isEmpty {
              Text("Nothing downloading. Tap ↓ beside an album, artist, playlist or track in Library.")
                .font(.callout).foregroundStyle(.secondary)
            } else {
              Text("Done: \(downloads.finished) saved or already there\(downloads.failed > 0 ? ", \(downloads.failed) failed" : "").")
                .font(.callout)
            }
            Label("Saving to \(downloads.destinationName)", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
          HStack {
            if let url = downloads.filesURL {
              Button("Show in Files", systemImage: "folder") { openURL(url) }
            }
            Spacer()
            if downloads.running {
              Button("Cancel", role: .destructive) { downloads.cancel() }
            } else if downloads.failed > 0 {
              Button("Retry Failed") { downloads.retryFailed() }
            }
          }
          .buttonStyle(.borderless)
        }
        Section {
          ForEach(downloads.jobs.reversed()) { job in
            HStack(spacing: 12) {
              icon(job.state).frame(width: 22)
              VStack(alignment: .leading, spacing: 2) {
                Text(job.title).lineLimit(1)
                Text(detail(job)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }
            }
          }
        }
      }
      .navigationTitle("Downloads")
      .toolbar {
        if !downloads.running && !downloads.jobs.isEmpty {
          Button("Clear") { downloads.clearFinished() }
        }
      }
    }
  }

  @ViewBuilder private func icon(_ state: DownloadJob.State) -> some View {
    switch state {
    case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
    case .downloading: ProgressView()
    case .saved: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.mint)
    case .skipped: Image(systemName: "equal.circle").foregroundStyle(.secondary)
    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }
  }

  private func detail(_ job: DownloadJob) -> String {
    switch job.state {
    case .skipped: return "Already in Files · \(job.path)"
    case .failed(let reason): return reason
    default: return job.path
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var downloads: DownloadManager
  @AppStorage("saveCovers") private var saveCovers = true
  @AppStorage("keepAwake") private var keepAwake = true
  @State private var choosingFolder = false
  @State private var confirmSignOut = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Plex") {
          LabeledContent("Account", value: account.userName.isEmpty ? "Signed in" : account.userName)
          if !account.servers.isEmpty {
            Picker("Server", selection: Binding(
              get: { account.server?.clientIdentifier ?? "" },
              set: { id in if let server = account.servers.first(where: { $0.clientIdentifier == id }) { Task { await account.choose(server: server) } } }
            )) {
              ForEach(account.servers) { Text($0.name + (($0.owned ?? false) ? "" : " (shared)")).tag($0.clientIdentifier) }
            }
          }
          if account.sections.count > 1 {
            Picker("Music Library", selection: Binding(
              get: { account.section?.key ?? "" },
              set: { key in if let section = account.sections.first(where: { $0.key == key }) { account.choose(section: section) } }
            )) {
              ForEach(account.sections) { Text($0.title).tag($0.key) }
            }
          }
          if account.connecting {
            HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }
          } else if let error = account.error {
            Text(error).font(.footnote).foregroundStyle(.red)
            Button("Try Again") { Task { await account.connect() } }
          } else if let url = account.serverURL {
            LabeledContent("Address", value: url.host ?? url.absoluteString).font(.footnote)
          }
        }
        Section {
          LabeledContent("Save to", value: downloads.destinationName)
          Button("Choose a Folder in Files…") { choosingFolder = true }
          if !downloads.usesOwnFolder {
            Button("Use On My \(UIDevice.current.model) › plickass") { downloads.useOwnFolder() }
          }
          Toggle("Save cover art (cover.jpg)", isOn: $saveCovers)
          Toggle("Keep screen on while downloading", isOn: $keepAwake)
        } header: {
          Text("Files")
        } footer: {
          Text("Music is saved as Artist / Album / 01 - Track, exactly as stored on your server (FLAC stays FLAC). Files already there are skipped, never overwritten. Keep plickass open for big downloads; it gets a few minutes to finish if you switch apps.")
        }
        Section("About") {
          LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
          Link("plickass on GitHub", destination: URL(string: "https://github.com/dustalexw/plickass")!)
          Text("Based on Plexamp Download Copier by Daniel Rahn. plickass is not affiliated with Plex.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
          Button("Sign Out", role: .destructive) { confirmSignOut = true }
        }
      }
      .navigationTitle("Settings")
      .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { downloads.useFolder(url) }
      }
      .confirmationDialog("Sign out of Plex?", isPresented: $confirmSignOut, titleVisibility: .visible) {
        Button("Sign Out", role: .destructive) { account.signOut() }
      } message: {
        Text("Music already saved to Files stays there.")
      }
    }
  }
}
