import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum PlexError: LocalizedError, Equatable {
  case http(Int)
  case unreadable
  case noServer
  case signedOut

  var errorDescription: String? {
    switch self {
    case .http(401): return "Plex didn’t accept the sign-in. Sign in again."
    case .http(let code): return "The Plex server answered with an error (\(code)). Try again."
    case .unreadable: return "Plex sent something plickass couldn’t read."
    case .noServer: return "None of this server’s addresses answered. Check that it’s on and reachable."
    case .signedOut: return "Sign in to Plex first."
    }
  }
}

/// Talks to plex.tv (sign-in and servers) and to a Plex Media Server (music).
/// Everything is read-only; the only thing written anywhere is the files you download.
struct PlexClient: Sendable {
  static let product = "plickass"
  var clientIdentifier: String
  var version = "1.0"
  var deviceName = "iPhone"
  var session: URLSession = .shared

  // MARK: Requests

  func headers(token: String?) -> [String: String] {
    var values = [
      "Accept": "application/json",
      "X-Plex-Product": Self.product,
      "X-Plex-Version": version,
      "X-Plex-Client-Identifier": clientIdentifier,
      "X-Plex-Platform": "iOS",
      "X-Plex-Device": "iPhone",
      "X-Plex-Device-Name": deviceName,
    ]
    if let token { values["X-Plex-Token"] = token }
    return values
  }

  func request(_ url: URL, token: String?, method: String = "GET", timeout: TimeInterval = 30) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    for (name, value) in headers(token: token) { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  private func load<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw PlexError.http(http.statusCode)
    }
    do { return try JSONDecoder().decode(T.self, from: data) } catch { throw PlexError.unreadable }
  }

  // MARK: plex.tv

  /// Starts a sign-in; open `authURL(for:)` and poll `checkPin` until it has a token.
  func createPin() async throws -> PlexPin {
    try await load(
      request(URL(string: "https://plex.tv/api/v2/pins?strong=true")!, token: nil, method: "POST"), as: PlexPin.self)
  }

  func checkPin(_ pin: PlexPin) async throws -> PlexPin {
    try await load(request(URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!, token: nil), as: PlexPin.self)
  }

  /// The plex.tv page where the user approves the sign-in.
  func authURL(for pin: PlexPin, forward: String? = nil) -> URL {
    var fragment = URLComponents()
    fragment.queryItems = [
      URLQueryItem(name: "clientID", value: clientIdentifier),
      URLQueryItem(name: "code", value: pin.code),
      URLQueryItem(name: "context[device][product]", value: Self.product),
    ]
    if let forward { fragment.queryItems?.append(URLQueryItem(name: "forwardUrl", value: forward)) }
    return URL(string: "https://app.plex.tv/auth#?" + (fragment.percentEncodedQuery ?? ""))!
  }

  func user(token: String) async throws -> PlexUser {
    try await load(request(URL(string: "https://plex.tv/api/v2/user")!, token: token), as: PlexUser.self)
  }

  /// Servers on the account, owned ones first.
  func servers(token: String) async throws -> [PlexResource] {
    let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1")!
    let all = try await load(request(url, token: token), as: [PlexResource].self)
    return all.filter(\.isServer).sorted { ($0.owned ?? false) && !($1.owned ?? false) }
  }

  /// Connection addresses to try, best first: local, then direct, then Plex's relay.
  static func orderedConnections(_ resource: PlexResource) -> [PlexConnection] {
    (resource.connections ?? []).sorted { a, b in
      func rank(_ c: PlexConnection) -> Int { c.relay ? 2 : c.local ? 0 : 1 }
      if rank(a) != rank(b) { return rank(a) < rank(b) }
      return a.uri.hasPrefix("https") && !b.uri.hasPrefix("https")
    }
  }

  /// The first address of the server that answers.
  func reachableURL(for resource: PlexResource) async throws -> URL {
    let token = resource.accessToken
    for connection in Self.orderedConnections(resource) {
      guard let base = URL(string: connection.uri) else { continue }
      var probe = request(base.appendingPathComponent("identity"), token: token, timeout: connection.relay ? 12 : 5)
      probe.cachePolicy = .reloadIgnoringLocalCacheData
      if let (_, response) = try? await session.data(for: probe), (response as? HTTPURLResponse)?.statusCode == 200 {
        return base
      }
    }
    throw PlexError.noServer
  }

  // MARK: A server

  func url(_ server: URL, _ path: String, _ query: [String: String] = [:]) -> URL {
    var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
    let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
    components.path = base + parts[0]
    var items = parts.count > 1 ? (URLComponents(string: "?" + parts[1])?.queryItems ?? []) : []
    items += query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    components.queryItems = items.isEmpty ? nil : items
    return components.url!
  }

  func container(_ server: URL, _ path: String, token: String, query: [String: String] = [:],
                 start: Int? = nil, size: Int? = nil) async throws -> PlexContainer {
    var request = request(url(server, path, query), token: token)
    if let start, let size {
      request.setValue(String(start), forHTTPHeaderField: "X-Plex-Container-Start")
      request.setValue(String(size), forHTTPHeaderField: "X-Plex-Container-Size")
    }
    return try await load(request, as: PlexEnvelope.self).MediaContainer
  }

  /// Music libraries on the server.
  func musicSections(_ server: URL, token: String) async throws -> [PlexDirectory] {
    try await container(server, "/library/sections", token: token).Directory?.filter { $0.type == "artist" } ?? []
  }

  enum Kind: Int { case artist = 8, album = 9, track = 10 }

  /// A page of a library's artists or albums, sorted the way Plexamp lists them.
  func items(_ server: URL, token: String, section: String, kind: Kind, start: Int, size: Int)
    async throws -> (items: [PlexItem], total: Int)
  {
    let sort = kind == .album ? "artist.titleSort,album.titleSort" : "titleSort"
    let page = try await container(server, "/library/sections/\(section)/all", token: token,
                                   query: ["type": String(kind.rawValue), "sort": sort], start: start, size: size)
    let items = page.Metadata ?? []
    return (items, page.totalSize ?? (start + items.count + (items.count == size ? size : 0)))
  }

  /// Audio playlists on the server.
  func playlists(_ server: URL, token: String) async throws -> [PlexItem] {
    try await container(server, "/playlists", token: token, query: ["playlistType": "audio"]).Metadata ?? []
  }

  /// An album's tracks, an artist's albums, or a playlist's tracks.
  func children(_ server: URL, token: String, of item: PlexItem) async throws -> [PlexItem] {
    let path = item.type == "playlist" ? "/playlists/\(item.ratingKey)/items" : "/library/metadata/\(item.ratingKey)/children"
    return try await container(server, path, token: token).Metadata ?? []
  }

  /// Every track to download for an artist, album, playlist or track.
  func tracks(_ server: URL, token: String, of item: PlexItem) async throws -> [PlexItem] {
    switch item.type {
    case "track": return [item]
    case "artist":
      return try await container(server, "/library/metadata/\(item.ratingKey)/allLeaves", token: token).Metadata ?? []
    default:
      return try await children(server, token: token, of: item).filter { $0.type == "track" }
    }
  }

  /// Artists, albums and tracks matching a search in one library.
  func search(_ server: URL, token: String, section: String, query: String) async throws -> [PlexItem] {
    let hubs = try await container(server, "/hubs/search", token: token,
                                   query: ["query": query, "sectionId": section, "limit": "25"]).Hub ?? []
    return hubs.filter { ["artist", "album", "track"].contains($0.type ?? "") }.flatMap { $0.Metadata ?? [] }
  }

  /// The original file of a track, as stored on the server.
  func downloadURL(_ server: URL, token: String, part: PlexPart) -> URL {
    url(server, part.key, ["download": "1", "X-Plex-Token": token])
  }

  /// A square thumbnail of artwork, scaled by the server.
  func imageURL(_ server: URL, token: String, path: String, size: Int) -> URL {
    url(server, "/photo/:/transcode", ["url": path, "width": String(size), "height": String(size),
                                        "minSize": "1", "upscale": "1", "X-Plex-Token": token])
  }

  /// Full-size artwork, for the album folder's cover.jpg.
  func originalImageURL(_ server: URL, token: String, path: String) -> URL {
    url(server, path, ["X-Plex-Token": token])
  }
}
