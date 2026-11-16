import AuthenticationServices
import Foundation
import Security
import SwiftUI
import UIKit

/// The Plex token, kept in the Keychain (this device only).
enum TokenKeychain {
  private static let account = "plex-token"
  private static let service = "com.dustalexw.plickass"

  static func read() -> String? {
    var result: AnyObject?
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true,
    ]
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(_ token: String?) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    guard let token else { return }
    var item = query
    item[kSecValueData as String] = Data(token.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }
}

/// Signing in to Plex, and which server and music library plickass reads.
@MainActor final class AccountStore: ObservableObject {
  @Published private(set) var token: String?
  @Published private(set) var userName = ""
  @Published private(set) var servers: [PlexResource] = []
  @Published private(set) var server: PlexResource?
  @Published private(set) var serverURL: URL?
  @Published private(set) var sections: [PlexDirectory] = []
  @Published private(set) var section: PlexDirectory?
  @Published private(set) var connecting = false
  @Published private(set) var signingIn = false
  @Published var error: String?

  let client: PlexClient
  private let defaults = UserDefaults.standard

  /// The token for the chosen server (shared servers have their own).
  var serverToken: String? { server?.accessToken ?? token }
  var ready: Bool { serverURL != nil && section != nil && serverToken != nil }

  init() {
    let id = defaults.string(forKey: "plex.clientIdentifier") ?? UUID().uuidString
    defaults.set(id, forKey: "plex.clientIdentifier")
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    client = PlexClient(clientIdentifier: id, version: version, deviceName: UIDevice.current.name)
    token = TokenKeychain.read()
    if token != nil { Task { await connect() } }
  }

  // MARK: Signing in

  /// Opens Plex's sign-in page; it hands back to plickass when you approve.
  func signIn(using session: WebAuthenticationSession) async {
    guard !signingIn else { return }
    signingIn = true
    error = nil
    defer { signingIn = false }
    do {
      let pin = try await client.createPin()
      let url = client.authURL(for: pin, forward: "plickass://signed-in")
      // The page redirects to plickass://signed-in when approved; closing it early
      // still checks the PIN, since approval may already have gone through.
      let finished = (try? await session.authenticate(using: url, callbackURLScheme: "plickass")) != nil
      var approved: String?
      for _ in 0..<(finished ? 10 : 1) {
        if let found = try await client.checkPin(pin).authToken { approved = found; break }
        try await Task.sleep(nanoseconds: 700_000_000)
      }
      guard let approved else { return }
      TokenKeychain.save(approved)
      token = approved
      await connect()
    } catch {
      self.error = error.localizedDescription
    }
  }

  func signOut() {
    TokenKeychain.save(nil)
    token = nil
    userName = ""
    servers = []
    server = nil
    serverURL = nil
    sections = []
    section = nil
    defaults.removeObject(forKey: "plex.server")
    defaults.removeObject(forKey: "plex.section")
  }

  // MARK: Server and library

  /// Finds the account's servers, reaches the chosen one and its music libraries.
  func connect() async {
    guard let token, !connecting else { return }
    connecting = true
    error = nil
    defer { connecting = false }
    do {
      if let user = try? await client.user(token: token) { userName = user.name }
      servers = try await client.servers(token: token)
      let saved = defaults.string(forKey: "plex.server")
      guard let chosen = servers.first(where: { $0.clientIdentifier == saved }) ?? servers.first else {
        error = "This Plex account has no servers. Add one at plex.tv, then try again."
        return
      }
      try await use(chosen)
    } catch PlexError.http(401) {
      signOut()
      error = PlexError.http(401).localizedDescription
    } catch {
      self.error = error.localizedDescription
    }
  }

  func choose(server: PlexResource) async {
    connecting = true
    error = nil
    defer { connecting = false }
    do { try await use(server) } catch { self.error = error.localizedDescription }
  }

  private func use(_ resource: PlexResource) async throws {
    server = resource
    serverURL = nil
    sections = []
    section = nil
    defaults.set(resource.clientIdentifier, forKey: "plex.server")
    let url = try await client.reachableURL(for: resource)
    let token = resource.accessToken ?? self.token ?? ""
    let music = try await client.musicSections(url, token: token)
    serverURL = url
    sections = music
    let saved = defaults.string(forKey: "plex.section")
    section = music.first { $0.key == saved } ?? music.first
    if music.isEmpty { error = "“\(resource.name)” has no music libraries." }
  }

  func choose(section: PlexDirectory) {
    self.section = section
    defaults.set(section.key, forKey: "plex.section")
  }

  /// Artwork for a list row or header, scaled by the server.
  func imageURL(_ path: String?, size: Int) -> URL? {
    guard let path, let serverURL, let token = serverToken else { return nil }
    return client.imageURL(serverURL, token: token, path: path, size: size)
  }
}
