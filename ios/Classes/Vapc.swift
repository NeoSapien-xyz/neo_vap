import Foundation

/// Integer pixel rectangle `[x, y, w, h]` from a `vapc` atom.
struct VapcRect {
  let x: Int
  let y: Int
  let w: Int
  let h: Int
}

/// Parsed `vapc` atom (the iOS mirror of `Vapc.kt` / `lib/src/vapc.dart`). The
/// native side reads the asset for AVPlayer anyway, so it parses its own crop
/// rects rather than threading them through the method channel.
struct VapcInfo {
  let version: Int
  let frameCount: Int
  let width: Int
  let height: Int
  let fps: Int
  let videoWidth: Int
  let videoHeight: Int
  let rgbFrame: VapcRect
  let aFrame: VapcRect
  let isVapx: Bool
  let orientation: Int

  /// Content aspect ratio (width / height).
  var aspectRatio: Double { height == 0 ? 1.0 : Double(width) / Double(height) }

  static func parse(_ bytes: Data) throws -> VapcInfo {
    let json = try extractVapcJson(bytes)
    guard
      let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
      let info = root["info"] as? [String: Any]
    else {
      throw VapcParseError("malformed vapc atom (no info object)")
    }
    func int(_ key: String) throws -> Int {
      guard let n = info[key] as? NSNumber else {
        throw VapcParseError("vapc info missing '\(key)'")
      }
      return n.intValue
    }
    func rect(_ key: String) throws -> VapcRect {
      guard let a = info[key] as? [Any], a.count >= 4 else {
        throw VapcParseError("vapc '\(key)' needs 4 elements")
      }
      let v = a.map { ($0 as? NSNumber)?.intValue ?? 0 }
      return VapcRect(x: v[0], y: v[1], w: v[2], h: v[3])
    }
    return VapcInfo(
      version: try int("v"),
      frameCount: try int("f"),
      width: try int("w"),
      height: try int("h"),
      fps: try int("fps"),
      videoWidth: try int("videoW"),
      videoHeight: try int("videoH"),
      rgbFrame: try rect("rgbFrame"),
      aFrame: try rect("aFrame"),
      isVapx: (info["isVapx"] as? NSNumber)?.intValue ?? 0 != 0,
      orientation: (info["orien"] as? NSNumber)?.intValue ?? 0
    )
  }

  /// Walk top-level mp4 boxes `[uint32 size][4-char type][payload]` and return
  /// the `vapc` box's UTF-8 JSON. size==1 -> 64-bit largesize, size==0 -> EOF.
  private static func extractVapcJson(_ bytes: Data) throws -> Data {
    let count = bytes.count
    var offset = 0
    func u32(_ at: Int) -> UInt64 {
      UInt64(bytes[at]) << 24 | UInt64(bytes[at + 1]) << 16
        | UInt64(bytes[at + 2]) << 8 | UInt64(bytes[at + 3])
    }
    func u64(_ at: Int) -> UInt64 {
      (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[at + $1]) }
    }
    while offset + 8 <= count {
      var size = u32(offset)
      var header = 8
      switch size {
      case 1:
        if offset + 16 > count { break }
        size = u64(offset + 8)
        header = 16
      case 0:
        size = UInt64(count - offset)
      default:
        break
      }
      if size < UInt64(header) || offset + Int(size) > count {
        throw VapcParseError("corrupt mp4 box at \(offset) (size \(size))")
      }
      let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)
      if type == "vapc" {
        let start = offset + header
        let end = offset + Int(size)
        // Drop trailing NUL box padding + whitespace before JSON parse.
        let slice = bytes[start..<end]
        let trimmed = slice.drop { $0 == 0 }.reversed().drop { $0 <= 0x20 }.reversed()
        return Data(trimmed)
      }
      offset += Int(size)
    }
    throw VapcParseError("no vapc atom found (not a VAP mp4?)")
  }
}

struct VapcParseError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}
