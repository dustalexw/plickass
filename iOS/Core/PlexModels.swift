import Foundation

/// A sign-in PIN from plex.tv. `authToken` appears once the user approves it.
struct PlexPin: Decodable, Equatable {
  let id: Int
  let code: String
  let authToken: String?
}

/// A Plex Media Server (or other device) on the account, from plex.tv.
struct PlexResource: Decodable, Identifiable, Equatable {
  let name: String
  let clientIdentifier: String
  let provides: String
  let accessToken: String?
  let owned: Bool?
  let presence: Bool?
  let connections: [PlexConnection]?
  var id: String { clientIdentifier }
  var isServer: Bool { provides.split(separator: ",").contains("server") }
}

struct PlexConnection: Decodable, Equatable {
  let uri: String
  let local: Bool
  let relay: Bool
}

/// The account signed in, from plex.tv.
struct PlexUser: Decodable, Equatable {
  let username: String?
  let title: String?
  let email: String?
  var name: String { username ?? title ?? email ?? "Plex account" }
}

/// `{"MediaContainer": {...}}`, the wrapper around every server response.
struct PlexEnvelope: Decodable {
  let MediaContainer: PlexContainer
}

struct PlexContainer: Decodable {
  let size: Int?
  let totalSize: Int?
  let Metadata: [PlexItem]?
  let Directory: [PlexDirectory]?
  let Hub: [PlexHub]?
}

/// A library section such as "Music".
struct PlexDirectory: Decodable, Identifiable, Equatable {
  let key: String
  let title: String
  let type: String?
  var id: String { key }
}

struct PlexHub: Decodable {
  let type: String?
  let Metadata: [PlexItem]?
}

/// An artist, album, track or playlist.
struct PlexItem: Decodable, Identifiable, Hashable {
  let ratingKey: String
  let key: String?
  let type: String
  let title: String
  let parentTitle: String?
  let grandparentTitle: String?
  let originalTitle: String?
  let parentRatingKey: String?
  let grandparentRatingKey: String?
  let index: Int?
  let parentIndex: Int?
  let year: Int?
  let thumb: String?
  let parentThumb: String?
  let composite: String?
  let leafCount: Int?
  let childCount: Int?
  let duration: Int?
  let playlistType: String?
  let Media: [PlexMedia]?
  var id: String { ratingKey }

  /// The file a download fetches: the track's first part, as stored on the server.
  var part: PlexPart? { Media?.first?.Part?.first }
  /// Artwork to show: the item's, its album's, or a playlist's mosaic.
  var artwork: String? { thumb ?? parentThumb ?? composite }
}

struct PlexMedia: Decodable, Hashable {
  let container: String?
  let audioCodec: String?
  let Part: [PlexPart]?
}

struct PlexPart: Decodable, Hashable {
  let key: String
  let file: String?
  let size: Int64?
  let container: String?
}
