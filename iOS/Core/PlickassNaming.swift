import Foundation

/// plickass's file layout, the same as the Mac app and Daniel Rahn's script:
/// `Artist / Album / 01 - Track.ext`. Albums with more than one disc get the disc
/// first (`1-01 - Track.ext`) so their tracks don't collide.
enum PlickassNaming {
  /// Replaces characters file systems reject (<>:"/\|?*), as the Mac script does,
  /// and trims what Files dislikes (leading dots, trailing dots and spaces).
  static func sanitize(_ name: String, fallback: String) -> String {
    var value = name.replacingOccurrences(of: "\u{2019}", with: "'")
    for ch in ["<", ">", "/", "\\", "|"] { value = value.replacingOccurrences(of: ch, with: "-") }
    value = value.replacingOccurrences(of: ":", with: " -")
    value = value.replacingOccurrences(of: "\"", with: "'")
    value = value.replacingOccurrences(of: "?", with: "").replacingOccurrences(of: "*", with: "")
    value = value.components(separatedBy: .controlCharacters).joined()
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix(".") { value.removeFirst() }
    while value.hasSuffix(".") || value.hasSuffix(" ") { value.removeLast() }
    if value.count > 180 { value = String(value.prefix(180)).trimmingCharacters(in: .whitespaces) }
    return value.isEmpty ? fallback : value
  }

  /// The file extension of a track's part: from the part's key or file, else its container.
  static func fileExtension(for item: PlexItem) -> String {
    let candidates = [item.part?.key, item.part?.file].compactMap { $0 }
    for path in candidates {
      let clean = path.split(separator: "?").first.map(String.init) ?? path
      let ext = (clean as NSString).pathExtension.lowercased()
      if !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) { return ext }
    }
    let container = (item.part?.container ?? item.Media?.first?.container ?? "").lowercased()
    switch container {
    case "mp4", "aac": return "m4a"
    case "": return "mp3"
    default: return container
    }
  }

  static func pad(_ number: Int, width: Int) -> String {
    let text = String(number)
    return String(repeating: "0", count: max(0, width - text.count)) + text
  }

  /// Where each track goes, relative to the destination folder. Track numbers are
  /// padded to the album's widest number, as in the Mac app.
  static func plan(_ tracks: [PlexItem]) -> [(track: PlexItem, path: String)] {
    struct AlbumInfo { var widest = 1; var discs = Set<Int>() }
    var albums: [String: AlbumInfo] = [:]
    func albumKey(_ t: PlexItem) -> String { t.parentRatingKey ?? ((t.grandparentTitle ?? "") + "\n" + (t.parentTitle ?? "")) }
    for track in tracks {
      var info = albums[albumKey(track), default: AlbumInfo()]
      info.widest = max(info.widest, track.index ?? 1)
      info.discs.insert(track.parentIndex ?? 1)
      albums[albumKey(track)] = info
    }
    var seen = Set<String>()
    var result: [(track: PlexItem, path: String)] = []
    for track in tracks where track.part != nil {
      let info = albums[albumKey(track)] ?? AlbumInfo()
      let artist = sanitize(track.grandparentTitle ?? "", fallback: "Unknown Artist")
      let album = sanitize(track.parentTitle ?? "", fallback: "Unknown Album")
      let number = pad(track.index ?? 1, width: String(info.widest).count)
      let prefix = info.discs.count > 1 ? "\(track.parentIndex ?? 1)-\(number)" : number
      let title = sanitize(track.title, fallback: "Unknown Track")
      let path = "\(artist)/\(album)/\(prefix) - \(title).\(fileExtension(for: track))"
      // The same track twice (a playlist that repeats one) is fetched once.
      guard seen.insert(path.lowercased()).inserted else { continue }
      result.append((track, path))
    }
    return result
  }

  /// The album folder for a track, for its cover image.
  static func albumFolder(for track: PlexItem) -> String {
    sanitize(track.grandparentTitle ?? "", fallback: "Unknown Artist") + "/"
      + sanitize(track.parentTitle ?? "", fallback: "Unknown Album")
  }
}
