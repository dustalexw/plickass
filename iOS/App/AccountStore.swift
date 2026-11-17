import AuthenticationServices
import Foundation
import Security
import SwiftUI
import UIKit

/// A small diagnostic log in Library/Logs/plickass.log (not shown in Files).
enum PlickassLog {
  static let url: URL = {
    let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("plickass.log")
  }()

  static func write(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
    } else {
      try? Data(line.utf8).write(to: url)
    }
    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 512 * 1024 {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

/// The Plex token: in the Keychain, with a copy in the app's own settings if the
/// Keychain refuses it, so a sign-in is never lost.
enum TokenStore {
  private static let account = "plex-token"
  private static let service = "com.dustalexw.plickass"
  private static let fallbackKey = "plex.token.fallback"

  private static var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  static func read() -> String? {
    var result: AnyObject?
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty {
      return token
    }
    if status != errSecItemNotFound { PlickassLog.write("keychain read status \(status)") }
    return UserDefaults.standard.string(forKey: fallbackKey)
  }

  static func save(_ token: String?) {
    SecItemDelete(query as CFDictionary)
    UserDefaults.standard.removeObject(forKey: fallbackKey)
    guard let token, !token.isEmpty else { return }
    var item = query
    item[kSecValueData as String] = Data(token.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(item as CFDictionary, nil)
    if status != errSecSuccess || read() != token {
      PlickassLog.write("keychain save status \(status); keeping the token in settings")
      UserDefaults.standard.set(token, forKey: fallbackKey)
    }
  }
}

/// What plickass last connected to, so the library opens at once on the next launch
/// while the connection is checked in the background.
private struct SavedConnection: Codable {
  var server: String
  var url: URL
  var sections: [SavedSection]
  var section: String?
}

private struct SavedSection: Codable {
  var key: String
  var title: String
}

/// Signing in to Plex, and which server and music library plickass reads.
@MainActor final class AccountStore: ObservableObject {
  @Published private(set) var token: String?
  @Published private(set) var userName = ""
  @Published private(set) var servers: [PlexResource] = []
  @Published private(set) var server: PlexResource?
  @Published private(set) var serverName = ""
  @Published private(set) var serverURL: URL?
  @Published private(set) var sections: [PlexDirectory] = []
  @Published private(set) var section: PlexDirectory?
  @Published private(set) var connecting = false
  @Published private(set) var signingIn = false
  @Published var error: String?

  let client: PlexClient
  private let defaults = UserDefaults.standard
  private var serverAccessToken: String?

  /// The token for the chosen server (shared servers have their own).
  var serverToken: String? { serverAccessToken ?? token }
  var ready: Bool { serverURL != nil && section != nil && serverToken != nil }

  init() {
    let id = defaults.string(forKey: "plex.clientIdentifier") ?? UUID().uuidString
    defaults.set(id, forKey: "plex.clientIdentifier")
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    client = PlexClient(clientIdentifier: id, version: version, deviceName: UIDevice.current.name)
    token = TokenStore.read()
    userName = defaults.string(forKey: "plex.userName") ?? ""
    PlickassLog.write("launch, signed in: \(token != nil)")
    if token != nil {
      restoreSavedConnection()
      Task { await connect() }
    }
  }

  // MARK: Signing in

  /// Opens Plex's sign-in page and waits for the approval. Plex hands back to plickass
  /// when you approve; the PIN is also checked meanwhile, so approving in Safari or
  /// on another device works too.
  func signIn(using session: WebAuthenticationSession) async {
    guard !signingIn else { return }
    signingIn = true
    error = nil
    defer { signingIn = false }
    do {
      let pin = try await client.createPin()
      let url = client.authURL(for: pin, forward: "plickass://signed-in")
      _ = try? await session.authenticate(using: url, callbackURLScheme: "plickass")
      // The page has closed: give Plex a moment to record the approval.
      var approved: String?
      for attempt in 0..<20 {
        do {
          if let found = try await client.checkPin(pin).authToken {
            approved = found
            break
          }
        } catch {
          PlickassLog.write("PIN check \(attempt): \(error)")
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
      guard let approved else {
        PlickassLog.write("sign-in closed without approval")
        error = "Sign-in wasn’t finished. Tap Sign In with Plex and approve plickass."
        return
      }
      PlickassLog.write("signed in")
      TokenStore.save(approved)
      token = approved
      await connect()
    } catch {
      PlickassLog.write("sign-in failed: \(error)")
      self.error = error.localizedDescription
    }
  }

  func signOut() {
    PlickassLog.write("signed out")
    TokenStore.save(nil)
    token = nil
    userName = ""
    servers = []
    server = nil
    serverName = ""
    serverURL = nil
    serverAccessToken = nil
    sections = []
    section = nil
    for key in ["plex.server", "plex.section", "plex.connection", "plex.userName", "plex.serverName", "plex.serverToken"] {
      defaults.removeObject(forKey: key)
    }
  }

  // MARK: Server and library

  private func restoreSavedConnection() {
    guard let data = defaults.data(forKey: "plex.connection"),
      let saved = try? JSONDecoder().decode(SavedConnection.self, from: data)
    else { return }
    serverURL = saved.url
    serverName = defaults.string(forKey: "plex.serverName") ?? ""
    serverAccessToken = defaults.string(forKey: "plex.serverToken")
    sections = saved.sections.map { PlexDirectory(key: $0.key, title: $0.title, type: "artist") }
    section = sections.first { $0.key == saved.section } ?? sections.first
  }

  private func saveConnection() {
    guard let server, let serverURL else { return }
    let saved = SavedConnection(
      server: server.clientIdentifier, url: serverURL,
      sections: sections.map { SavedSection(key: $0.key, title: $0.title) }, section: section?.key)
    defaults.set(try? JSONEncoder().encode(saved), forKey: "plex.connection")
    defaults.set(server.name, forKey: "plex.serverName")
    defaults.set(server.accessToken, forKey: "plex.serverToken")
  }

  /// Finds the account's servers and opens the music library: the one used last, or
  /// the first of your own servers that is online and has music.
  func connect() async {
    guard let token, !connecting else { return }
    connecting = true
    error = nil
    defer { connecting = false }
    do {
      if let user = try? await client.user(token: token) {
        userName = user.name
        defaults.set(user.name, forKey: "plex.userName")
      }
      servers = try await client.servers(token: token)
      PlickassLog.write(
        "servers: " + servers.map { "\($0.name) owned=\($0.owned ?? false) online=\($0.presence ?? false)" }.joined(separator: ", "))
      guard !servers.isEmpty else {
        error = "This Plex account has no servers. Add one at plex.tv, then try again."
        return
      }
      let saved = defaults.string(forKey: "plex.server")
      func rank(_ s: PlexResource) -> Int {
        (s.clientIdentifier == saved ? 0 : 4) + ((s.owned ?? false) ? 0 : 2) + ((s.presence ?? true) ? 0 : 1)
      }
      var lastError: Error?
      for candidate in servers.sorted(by: { rank($0) < rank($1) }) {
        do {
          try await use(candidate)
          if !sections.isEmpty {
            error = nil
            return
          }
        } catch {
          PlickassLog.write("\(candidate.name): \(error)")
          lastError = error
        }
      }
      if let lastError { throw lastError }
    } catch PlexError.http(401) {
      // Only a rejected account token signs you out; a server's error doesn't.
      if (try? await client.user(token: token)) == nil {
        signOut()
        error = PlexError.http(401).localizedDescription
      } else {
        error = "The server didn’t accept this account. Choose another server in Settings."
      }
    } catch {
      PlickassLog.write("connect failed: \(error)")
      // A saved connection keeps the library usable while the server is unreachable.
      if serverURL == nil { self.error = error.localizedDescription }
    }
  }

  func choose(server: PlexResource) async {
    connecting = true
    error = nil
    defer { connecting = false }
    do { try await use(server) } catch { self.error = error.localizedDescription }
  }

  private func use(_ resource: PlexResource) async throws {
    let token = resource.accessToken ?? self.token ?? ""
    let url = try await client.reachableURL(for: resource)
    let music = try await client.musicSections(url, token: token)
    PlickassLog.write("using \(resource.name) at \(url.host ?? "?"), music libraries: \(music.map(\.title))")
    server = resource
    serverName = resource.name
    serverAccessToken = resource.accessToken
    serverURL = url
    sections = music
    defaults.set(resource.clientIdentifier, forKey: "plex.server")
    let saved = defaults.string(forKey: "plex.section")
    section = music.first { $0.key == saved } ?? music.first
    saveConnection()
    if music.isEmpty { error = "“\(resource.name)” has no music libraries." }
  }

  func choose(section: PlexDirectory) {
    self.section = section
    defaults.set(section.key, forKey: "plex.section")
    saveConnection()
  }

  /// Artwork for a list row or header, scaled by the server.
  func imageURL(_ path: String?, size: Int) -> URL? {
    guard let path, let serverURL, let token = serverToken else { return nil }
    return client.imageURL(serverURL, token: token, path: path, size: size)
  }
}
