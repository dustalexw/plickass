import Foundation
import SwiftUI
import UIKit

/// One track on its way into Files.
struct DownloadJob: Identifiable, Equatable {
  enum State: Equatable {
    case queued, downloading, saved, skipped
    case failed(String)
  }
  let id = UUID()
  let title: String
  let detail: String
  let path: String
  let source: URL
  let size: Int64?
  let cover: URL?
  var state: State = .queued
}

/// Downloads tracks from the Plex server and saves them as
/// `Artist / Album / 01 - Track.ext` in Files, never overwriting what's there.
@MainActor final class DownloadManager: ObservableObject {
  @Published private(set) var jobs: [DownloadJob] = []
  @Published private(set) var running = false
  @Published private(set) var bytesSaved: Int64 = 0
  @Published private(set) var destinationName = ""
  @Published var notice: String?
  private let defaults = UserDefaults.standard
  /// Settings › Save Cover Art (cover.jpg in each album folder).
  var saveCovers: Bool { defaults.object(forKey: "saveCovers") as? Bool ?? true }
  /// Settings › Keep Screen On While Downloading.
  var keepAwake: Bool { defaults.object(forKey: "keepAwake") as? Bool ?? true }
  /// A folder chosen in Files, kept as a bookmark; nil means plickass's own folder.
  private var bookmark: Data? {
    get { defaults.data(forKey: "destinationBookmark") }
    set { defaults.set(newValue, forKey: "destinationBookmark") }
  }

  private var worker: Task<Void, Never>?
  private var background: UIBackgroundTaskIdentifier = .invalid
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 60 * 60 * 6
    configuration.waitsForConnectivity = true
    return URLSession(configuration: configuration)
  }()

  init() { destinationName = describe(destination().url) }

  var pending: Int { jobs.filter { $0.state == .queued || $0.state == .downloading }.count }
  var finished: Int { jobs.filter { $0.state == .saved || $0.state == .skipped }.count }
  var failed: Int { jobs.filter { if case .failed = $0.state { return true } else { return false } }.count }
  var usesOwnFolder: Bool { bookmark == nil }

  // MARK: Where files go

  /// plickass's folder in Files: On My iPhone › plickass.
  static var ownFolder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

  private func destination() -> (url: URL, scoped: Bool) {
    if let bookmark {
      var stale = false
      if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
        if stale, url.startAccessingSecurityScopedResource() {
          self.bookmark = try? url.bookmarkData()
          url.stopAccessingSecurityScopedResource()
        }
        return (url, true)
      }
    }
    return (Self.ownFolder, false)
  }

  private func describe(_ url: URL) -> String {
    bookmark == nil ? "On My \(UIDevice.current.model) › plickass" : url.lastPathComponent
  }

  /// Uses a folder picked in Files (iCloud Drive, a USB drive, another app's folder…).
  func useFolder(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      bookmark = try url.bookmarkData()
      destinationName = describe(url)
    } catch {
      notice = "plickass can’t save to that folder: \(error.localizedDescription)"
    }
  }

  func useOwnFolder() {
    bookmark = nil
    destinationName = describe(Self.ownFolder)
  }

  /// A link that opens the destination in the Files app.
  var filesURL: URL? {
    let url = destination().url
    return URL(string: "shareddocuments://" + url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
  }

  /// Which of these relative paths already exist in the destination.
  func existing(_ paths: [String]) -> Set<String> {
    let (root, scoped) = destination()
    let accessing = scoped && root.startAccessingSecurityScopedResource()
    defer { if accessing { root.stopAccessingSecurityScopedResource() } }
    return Set(paths.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
  }

  // MARK: Queue

  /// Adds tracks to the queue, named like the Mac app, and starts downloading.
  func enqueue(_ tracks: [PlexItem], account: AccountStore) {
    guard let server = account.serverURL, let token = account.serverToken else {
      notice = PlexError.signedOut.localizedDescription
      return
    }
    let client = account.client
    let queued = Set(jobs.filter { $0.state == .queued || $0.state == .downloading }.map(\.path))
    var added = 0
    for (track, path) in PlickassNaming.plan(tracks) where !queued.contains(path) {
      guard let part = track.part else { continue }
      let artist = track.originalTitle ?? track.grandparentTitle ?? ""
      let art = track.parentThumb ?? track.thumb
      jobs.append(DownloadJob(
        title: track.title, detail: [artist, track.parentTitle ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
        path: path, source: client.downloadURL(server, token: token, part: part), size: part.size,
        cover: art.map { client.originalImageURL(server, token: token, path: $0) }))
      added += 1
    }
    if added == 0 { notice = tracks.isEmpty ? "There’s nothing to download here." : "Those tracks are already queued." }
    start()
  }

  func cancel() {
    worker?.cancel()
    for i in jobs.indices where jobs[i].state == .queued || jobs[i].state == .downloading {
      jobs[i].state = .failed("Cancelled")
    }
  }

  func clearFinished() {
    jobs.removeAll { $0.state != .queued && $0.state != .downloading }
    bytesSaved = 0
  }

  func retryFailed() {
    for i in jobs.indices { if case .failed = jobs[i].state { jobs[i].state = .queued } }
    start()
  }

  private func start() {
    guard !running, jobs.contains(where: { $0.state == .queued }) else { return }
    running = true
    UIApplication.shared.isIdleTimerDisabled = keepAwake
    // A few minutes to finish the current files if you leave the app.
    background = UIApplication.shared.beginBackgroundTask(withName: "plickass downloads") { [weak self] in
      MainActor.assumeIsolated { self?.endBackground() }
    }
    worker = Task { [weak self] in
      await self?.drain()
      self?.finish()
    }
  }

  private func finish() {
    running = false
    UIApplication.shared.isIdleTimerDisabled = false
    endBackground()
    let saved = jobs.filter { $0.state == .saved }.count
    if failed > 0 { notice = "\(failed) track\(failed == 1 ? "" : "s") couldn’t be saved. Retry them from Downloads." }
    else if saved > 0, UIApplication.shared.applicationState != .active { notice = "Saved \(saved) tracks." }
  }

  private func endBackground() {
    if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
    background = .invalid
  }

  /// Two downloads at a time until the queue is empty.
  private func drain() async {
    let (root, scoped) = destination()
    let accessing = scoped && root.startAccessingSecurityScopedResource()
    defer { if accessing { root.stopAccessingSecurityScopedResource() } }
    if scoped && !accessing {
      notice = "plickass lost access to “\(root.lastPathComponent)”. Choose the folder again in Settings."
      for i in jobs.indices where jobs[i].state == .queued { jobs[i].state = .failed("No access to the folder") }
      return
    }
    await withTaskGroup(of: Void.self) { group in
      var active = 0
      while !Task.isCancelled {
        guard let index = jobs.firstIndex(where: { $0.state == .queued }) else {
          if active == 0 { break }
          await group.next()
          active -= 1
          continue
        }
        if active >= 2 {
          await group.next()
          active -= 1
          continue
        }
        jobs[index].state = .downloading
        let job = jobs[index]
        active += 1
        group.addTask { [weak self] in
          let result = await self?.save(job, root: root) ?? .failed("Cancelled")
          await self?.update(job.id, result)
        }
      }
      group.cancelAll()
    }
  }

  private func update(_ id: UUID, _ state: DownloadJob.State) {
    guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
    jobs[i].state = state
    if state == .saved { bytesSaved += jobs[i].size ?? 0 }
  }

  nonisolated private func save(_ job: DownloadJob, root: URL) async -> DownloadJob.State {
    let target = root.appendingPathComponent(job.path)
    let manager = FileManager.default
    if manager.fileExists(atPath: target.path) { return .skipped }
    do {
      try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      let (temporary, response) = try await session.download(for: URLRequest(url: job.source))
      defer { try? manager.removeItem(at: temporary) }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return .failed(code == 401 ? "Plex didn’t accept the sign-in" : "The server answered \(code)")
      }
      // Another download may have created it meanwhile; never overwrite.
      if manager.fileExists(atPath: target.path) { return .skipped }
      try manager.moveItem(at: temporary, to: target)
      if let cover = job.cover { await saveCover(cover, folder: target.deletingLastPathComponent()) }
      return .saved
    } catch is CancellationError {
      return .failed("Cancelled")
    } catch {
      if (error as? URLError)?.code == .cancelled { return .failed("Cancelled") }
      return .failed(error.localizedDescription)
    }
  }

  /// cover.jpg in the album's folder, once, when Save cover art is on.
  nonisolated private func saveCover(_ url: URL, folder: URL) async {
    guard await MainActor.run(body: { saveCovers }) else { return }
    let target = folder.appendingPathComponent("cover.jpg")
    guard !FileManager.default.fileExists(atPath: target.path),
      let loaded = try? await session.data(from: url),
      (loaded.1 as? HTTPURLResponse)?.statusCode == 200, loaded.0.count > 100,
      !FileManager.default.fileExists(atPath: target.path)
    else { return }
    try? loaded.0.write(to: target, options: .withoutOverwriting)
  }
}
