import SwiftUI

/// Album, artist and playlist artwork from the server.
struct Artwork: View {
  let path: String?
  var size: CGFloat = 52
  var round = false
  @EnvironmentObject private var account: AccountStore
  @Environment(\.displayScale) private var scale

  var body: some View {
    AsyncImage(url: account.imageURL(path, size: Int(size * scale))) { phase in
      if let image = phase.image {
        image.resizable().scaledToFill()
      } else {
        ZStack {
          Brand.coal
          Image(systemName: round ? "music.mic" : "opticaldisc").foregroundStyle(Brand.amber.opacity(0.6))
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)))
    .accessibilityHidden(true)
  }
}

/// Browse the music library by album, artist or playlist, like Plexamp, and
/// download any of them.
struct LibraryView: View {
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var downloads: DownloadManager
  @AppStorage("library.mode") private var mode = Mode.albums
  @State private var items: [PlexItem] = []
  @State private var total = 0
  @State private var loading = false
  @State private var failure: String?
  @State private var query = ""
  @State private var results: [PlexItem] = []
  @State private var searching = false

  enum Mode: String, CaseIterable, Identifiable {
    case albums = "Albums", artists = "Artists", playlists = "Playlists"
    var id: String { rawValue }
  }

  private var loadKey: String { "\(account.serverURL?.absoluteString ?? "")|\(account.section?.key ?? "")|\(mode.rawValue)" }

  var body: some View {
    NavigationStack {
      Group {
        if !account.ready {
          connectingView
        } else if !query.isEmpty {
          searchList
        } else {
          libraryList
        }
      }
      .navigationTitle(account.section?.title ?? "Library")
      .toolbar {
        ToolbarItem(placement: .principal) {
          Picker("Show", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).frame(width: 280).disabled(!account.ready)
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "Artists, albums, tracks")
      .task(id: loadKey) { await reload() }
      .task(id: query) { await search() }
      .refreshable { await reload() }
      .navigationDestination(for: PlexItem.self) { ItemView(item: $0) }
    }
  }

  @ViewBuilder private var connectingView: some View {
    if account.connecting {
      ProgressView("Connecting to \(account.server?.name ?? "your server")…")
    } else {
      ContentUnavailableView {
        Label("Not connected", systemImage: "server.rack")
      } description: {
        Text(account.error ?? "Choose a server and music library in Settings.")
      } actions: {
        Button("Try Again") { Task { await account.connect() } }.buttonStyle(.borderedProminent)
      }
    }
  }

  private var libraryList: some View {
    List {
      if let failure {
        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      ForEach(items) { item in
        row(item).onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
      }
      if loading { HStack { Spacer(); ProgressView(); Spacer() } }
    }
    .listStyle(.plain)
    .overlay {
      if !loading && items.isEmpty && failure == nil {
        ContentUnavailableView("Nothing here", systemImage: "music.note.list",
                               description: Text(mode == .playlists ? "This server has no music playlists." : "This library is empty."))
      }
    }
  }

  private var searchList: some View {
    List {
      ForEach(results) { row($0) }
    }
    .listStyle(.plain)
    .overlay {
      if searching { ProgressView() } else if results.isEmpty { ContentUnavailableView.search(text: query) }
    }
  }

  @ViewBuilder private func row(_ item: PlexItem) -> some View {
    let content = HStack(spacing: 12) {
      Artwork(path: item.artwork, round: item.type == "artist")
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title).font(.body.weight(.medium)).lineLimit(1)
        Text(subtitle(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      Button {
        Task { await download(item) }
      } label: {
        Image(systemName: "arrow.down.circle").font(.title2)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Download \(item.title)")
    }
    if item.type == "track" {
      content
    } else {
      NavigationLink(value: item) { content }
    }
  }

  private func subtitle(_ item: PlexItem) -> String {
    switch item.type {
    case "album": return [item.parentTitle, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    case "artist": return item.childCount.map { "\($0) album\($0 == 1 ? "" : "s")" } ?? "Artist"
    case "playlist": return item.leafCount.map { "\($0) track\($0 == 1 ? "" : "s")" } ?? "Playlist"
    case "track": return [item.grandparentTitle, item.parentTitle].compactMap { $0 }.joined(separator: " · ")
    default: return ""
    }
  }

  private func download(_ item: PlexItem) async {
    guard let server = account.serverURL, let token = account.serverToken else { return }
    do {
      downloads.enqueue(try await account.client.tracks(server, token: token, of: item), account: account)
    } catch {
      downloads.notice = error.localizedDescription
    }
  }

  // MARK: Loading

  private static let page = 150

  private func reload() async {
    items = []
    total = 0
    failure = nil
    await loadMore()
  }

  private func loadMore() async {
    guard account.ready, !loading, let server = account.serverURL, let token = account.serverToken,
      let section = account.section, items.isEmpty || items.count < total
    else { return }
    loading = true
    defer { loading = false }
    do {
      switch mode {
      case .playlists:
        guard items.isEmpty else { return }
        items = try await account.client.playlists(server, token: token)
        total = items.count
      case .albums, .artists:
        let page = try await account.client.items(server, token: token, section: section.key,
                                                  kind: mode == .albums ? .album : .artist, start: items.count, size: Self.page)
        items += page.items.filter { new in !items.contains { $0.id == new.id } }
        total = page.items.isEmpty ? items.count : page.total
      }
    } catch is CancellationError {
    } catch {
      if (error as? URLError)?.code != .cancelled { failure = error.localizedDescription }
    }
  }

  private func search() async {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, let server = account.serverURL, let token = account.serverToken, let section = account.section else {
      results = []
      return
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard !Task.isCancelled else { return }
    searching = true
    defer { searching = false }
    results = (try? await account.client.search(server, token: token, section: section.key, query: text)) ?? []
  }
}

/// An album, artist or playlist: its tracks (or albums), which are already in Files,
/// and a button to download the rest.
struct ItemView: View {
  let item: PlexItem
  @EnvironmentObject private var account: AccountStore
  @EnvironmentObject private var downloads: DownloadManager
  @State private var children: [PlexItem] = []
  @State private var saved = Set<String>()
  @State private var paths: [String: String] = [:]
  @State private var loading = true
  @State private var failure: String?

  private var tracks: [PlexItem] { children.filter { $0.type == "track" } }

  var body: some View {
    List {
      Section {
        VStack(spacing: 14) {
          Artwork(path: item.artwork, size: 220, round: item.type == "artist")
          Text(item.title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
          if let by = item.type == "album" ? item.parentTitle : nil {
            Text(by).font(.headline).foregroundStyle(.secondary)
          }
          Button {
            Task { await downloadAll() }
          } label: {
            Label(buttonTitle, systemImage: "arrow.down.circle.fill").font(.headline).frame(maxWidth: 300).padding(.vertical, 6)
          }
          .buttonStyle(.borderedProminent).foregroundStyle(.black)
          .disabled(loading || (!tracks.isEmpty && saved.count == tracks.count))
          if !tracks.isEmpty {
            Text(saved.isEmpty ? "\(tracks.count) tracks" : "\(saved.count) of \(tracks.count) already in Files")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity).listRowBackground(Color.clear).padding(.vertical, 8)
      }
      if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
      Section {
        ForEach(children) { child in
          if child.type == "track" {
            trackRow(child)
          } else {
            NavigationLink(value: child) {
              HStack(spacing: 12) {
                Artwork(path: child.artwork)
                VStack(alignment: .leading) {
                  Text(child.title).lineLimit(1)
                  if let year = child.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
                }
              }
            }
          }
        }
      }
    }
    .overlay { if loading { ProgressView() } }
    .navigationTitle(item.title)
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .onChange(of: downloads.finished) { _, _ in refreshSaved() }
  }

  private var buttonTitle: String {
    switch item.type {
    case "artist": return "Download All Albums"
    case "playlist": return "Download Playlist"
    default: return saved.isEmpty ? "Download Album" : "Download the Rest"
    }
  }

  private func trackRow(_ track: PlexItem) -> some View {
    HStack(spacing: 12) {
      Text(track.index.map(String.init) ?? "–").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
      VStack(alignment: .leading, spacing: 2) {
        Text(track.title).lineLimit(1)
        if item.type == "playlist" || track.originalTitle != nil {
          Text(track.originalTitle ?? track.grandparentTitle ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer()
      if let path = paths[track.id], saved.contains(path) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.mint).accessibilityLabel("In Files")
      } else {
        Button {
          downloads.enqueue([track], account: account)
        } label: {
          Image(systemName: "arrow.down.circle")
        }
        .buttonStyle(.borderless).accessibilityLabel("Download \(track.title)")
      }
    }
  }

  private func load() async {
    guard let server = account.serverURL, let token = account.serverToken else { return }
    loading = true
    defer { loading = false }
    do {
      children = try await account.client.children(server, token: token, of: item)
      paths = Dictionary(PlickassNaming.plan(tracks).map { ($0.track.id, $0.path) }, uniquingKeysWith: { a, _ in a })
      refreshSaved()
    } catch {
      failure = error.localizedDescription
    }
  }

  private func refreshSaved() { saved = downloads.existing(Array(paths.values)) }

  private func downloadAll() async {
    guard let server = account.serverURL, let token = account.serverToken else { return }
    do {
      let all = item.type == "artist" ? try await account.client.tracks(server, token: token, of: item) : tracks
      downloads.enqueue(all, account: account)
    } catch {
      downloads.notice = error.localizedDescription
    }
  }
}
