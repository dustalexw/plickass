import XCTest

@testable import PlickassCore

final class PlickassCoreTests: XCTestCase {
  private func track(_ title: String, index: Int?, disc: Int? = nil, album: String? = "Album", artist: String? = "Artist",
                     albumKey: String = "a1", key: String = "/library/parts/1/2/file.flac") -> PlexItem {
    let json = """
    {"ratingKey":"\(UUID().uuidString)","type":"track","title":\(String(reflecting: title)),
     \(album.map { "\"parentTitle\":\(String(reflecting: $0))," } ?? "")
     \(artist.map { "\"grandparentTitle\":\(String(reflecting: $0))," } ?? "")
     "parentRatingKey":"\(albumKey)",\(index.map { "\"index\":\($0)," } ?? "")\(disc.map { "\"parentIndex\":\($0)," } ?? "")
     "Media":[{"container":"flac","Part":[{"key":"\(key)","size":10}]}]}
    """
    return try! JSONDecoder().decode(PlexItem.self, from: Data(json.utf8))
  }

  func testSanitizeMatchesTheMacScript() {
    XCTAssertEqual(PlickassNaming.sanitize("AC/DC: Live? \"Yes\" <now>*", fallback: "x"), "AC-DC - Live 'Yes' -now-")
    XCTAssertEqual(PlickassNaming.sanitize("Don\u{2019}t", fallback: "x"), "Don't")
    XCTAssertEqual(PlickassNaming.sanitize(" ...Hidden. ", fallback: "x"), "Hidden")
    XCTAssertEqual(PlickassNaming.sanitize("???", fallback: "Unknown"), "Unknown")
  }

  func testPlanPadsToTheAlbumsWidestTrack() {
    let tracks = (1...12).map { (n: Int) in track("Song \(n)", index: n) }
    let plan = PlickassNaming.plan(tracks)
    XCTAssertEqual(plan.first?.path, "Artist/Album/01 - Song 1.flac")
    XCTAssertEqual(plan.last?.path, "Artist/Album/12 - Song 12.flac")
  }

  func testPlanMultiDiscFallbacksAndDuplicates() {
    let tracks = [
      track("Intro", index: 1, disc: 1), track("Outro", index: 1, disc: 2),
      track("Loose", index: nil, album: nil, artist: nil, albumKey: "b"),
      track("Intro", index: 1, disc: 1),
    ]
    XCTAssertEqual(PlickassNaming.plan(tracks).map(\.path), [
      "Artist/Album/1-1 - Intro.flac", "Artist/Album/2-1 - Outro.flac", "Unknown Artist/Unknown Album/1 - Loose.flac",
    ])
  }

  func testFileExtension() {
    XCTAssertEqual(PlickassNaming.fileExtension(for: track("a", index: 1, key: "/library/parts/9/1/file.m4a")), "m4a")
    XCTAssertEqual(PlickassNaming.fileExtension(for: track("a", index: 1, key: "/library/parts/9/1/file")), "flac")
  }

  func testDecodesServerResponses() throws {
    let json = """
    {"MediaContainer":{"size":2,"totalSize":40,"Metadata":[
      {"ratingKey":"10","key":"/library/metadata/10/children","type":"album","title":"Screamadelica",
       "parentTitle":"Primal Scream","thumb":"/library/metadata/10/thumb/1","leafCount":11,"year":1991}],
     "Directory":[{"key":"3","title":"Music","type":"artist"},{"key":"1","title":"Movies","type":"movie"}]}}
    """
    let container = try JSONDecoder().decode(PlexEnvelope.self, from: Data(json.utf8)).MediaContainer
    XCTAssertEqual(container.totalSize, 40)
    XCTAssertEqual(container.Metadata?.first?.title, "Screamadelica")
    XCTAssertEqual(container.Metadata?.first?.artwork, "/library/metadata/10/thumb/1")
    XCTAssertEqual(container.Directory?.filter { $0.type == "artist" }.map(\.title), ["Music"])
    let resources = """
    [{"name":"Den","clientIdentifier":"abc","provides":"server","accessToken":"t","owned":true,
      "connections":[{"uri":"https://1-2-3-4.x.plex.direct:32400","local":false,"relay":false},
                     {"uri":"https://relay.plex.direct:8443","local":false,"relay":true},
                     {"uri":"http://192.168.1.5:32400","local":true,"relay":false}]},
     {"name":"Phone","clientIdentifier":"p","provides":"client,player"}]
    """
    let list = try JSONDecoder().decode([PlexResource].self, from: Data(resources.utf8))
    XCTAssertEqual(list.filter(\.isServer).map(\.name), ["Den"])
    XCTAssertEqual(PlexClient.orderedConnections(list[0]).map(\.uri), [
      "http://192.168.1.5:32400", "https://1-2-3-4.x.plex.direct:32400", "https://relay.plex.direct:8443",
    ])
  }

  func testURLs() {
    let client = PlexClient(clientIdentifier: "id-1")
    let server = URL(string: "https://1-2-3-4.x.plex.direct:32400")!
    let part = PlexPart(key: "/library/parts/5/123/file.flac", file: nil, size: nil, container: nil)
    XCTAssertEqual(client.downloadURL(server, token: "tok", part: part).absoluteString,
                   "https://1-2-3-4.x.plex.direct:32400/library/parts/5/123/file.flac?X-Plex-Token=tok&download=1")
    XCTAssertEqual(client.url(server, "/library/sections/3/all?type=9", ["sort": "titleSort"]).absoluteString,
                   "https://1-2-3-4.x.plex.direct:32400/library/sections/3/all?type=9&sort=titleSort")
    let auth = client.authURL(for: PlexPin(id: 1, code: "ABCD", authToken: nil)).absoluteString
    XCTAssertTrue(auth.hasPrefix("https://app.plex.tv/auth#?clientID=id-1&code=ABCD&context%5Bdevice%5D%5Bproduct%5D=plickass"), auth)
  }
}
