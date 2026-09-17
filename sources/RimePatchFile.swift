//
//  RimePatchFile.swift
//  Bangke
//

import Foundation

/// A Rime `*.custom.yaml` patch file, edited key by key instead of regenerated.
///
/// These files are shared with the installer and with hand edits, so a rewrite
/// must leave every line the settings UI does not own untouched — comments
/// included. librime cannot do this for us: its C API writes nothing back to
/// disk, and the C++ `Config::SaveToFile` round-trips through yaml-cpp, which
/// drops comments and reorders keys. Hence line-level editing, the same
/// discipline the Windows and Linux frontends use.
struct RimePatchFile {
  private struct KeyLocation {
    var index = -1
    var indent = -1
  }

  private(set) var lines: [String]

  init(lines: [String] = []) {
    self.lines = lines
  }

  init(contentsOf url: URL) {
    self.init(lines: Self.split((try? String(contentsOf: url, encoding: .utf8)) ?? ""))
  }

  var text: String {
    lines.map { $0 + "\n" }.joined()
  }

  // MARK: - Reading

  /// Value of a top-level patch key, e.g. `style/font_face`.
  func scalar(_ key: String) -> String? {
    let location = location(of: key)
    return location.index >= 0 ? scalarValue(of: lines[location.index]) : nil
  }

  /// Value of a key nested one level down, e.g. `enabled` inside `ai_predict:`.
  func scalar(inBlock block: String, _ key: String) -> String? {
    guard let index = blockBodyIndex(of: block, matching: key) else { return nil }
    return scalarValue(of: lines[index])
  }

  /// Direct children of `patch:` whose key starts with `prefix`. Patch keys are
  /// namespaced paths rather than nested maps, so `ascii_composer/switch_key/`
  /// matches a whole family with one scan.
  func scalars(withPrefix prefix: String) -> [(key: String, value: String)] {
    let patchLocation = location(of: "patch")
    guard patchLocation.index >= 0 else { return [] }
    var result = [(key: String, value: String)]()
    for index in (patchLocation.index + 1)..<lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if leadingSpaces(line) <= patchLocation.indent { break }
      guard let colon = trimmed.firstIndex(of: ":"),
            trimmed[trimmed.startIndex..<colon].hasPrefix(prefix),
            let value = scalarValue(of: line) else { continue }
      result.append((String(trimmed[trimmed.startIndex..<colon]), value))
    }
    return result
  }

  /// Every key/value pair inside a nested block.
  func scalars(inBlock block: String) -> [(key: String, value: String)] {
    let blockLocation = location(of: block)
    guard blockLocation.index >= 0 else { return [] }
    var result = [(key: String, value: String)]()
    for index in (blockLocation.index + 1)..<lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if leadingSpaces(line) <= blockLocation.indent { break }
      guard let colon = trimmed.firstIndex(of: ":"),
            let value = scalarValue(of: line) else { continue }
      result.append((String(trimmed[trimmed.startIndex..<colon]), value))
    }
    return result
  }

  // MARK: - Writing

  mutating func setScalar(_ key: String, to value: String) {
    let location = location(of: key)
    let indent = location.indent >= 0 ? location.indent : 2
    let line = String(repeating: " ", count: indent) + key + ": " + value
    if location.index >= 0 {
      lines[location.index] = line
    } else {
      insertAfterPatch(line)
    }
  }

  mutating func setScalar(inBlock block: String, _ key: String, to value: String) {
    var blockLocation = location(of: block)
    if blockLocation.index < 0 {
      insertAfterPatch("  " + block + ":")
      blockLocation = location(of: block)
    }
    guard blockLocation.index >= 0 else { return }

    var targetIndex = -1
    var blockEnd = blockLocation.index
    for index in (blockLocation.index + 1)..<lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if leadingSpaces(line) <= blockLocation.indent { break }
      if trimmed.hasPrefix(key + ":") { targetIndex = index }
      blockEnd = index
    }

    let line = String(repeating: " ", count: blockLocation.indent + 2) + key + ": " + value
    if targetIndex >= 0 {
      lines[targetIndex] = line
    } else {
      // Append at the block's end so existing keys keep their position and new
      // keys follow the caller's order.
      lines.insert(line, at: blockEnd + 1)
    }
  }

  func write(to url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - Line primitives

  private static func split(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" {
      lines.removeLast()
    }
    return lines
  }

  private func leadingSpaces(_ line: String) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.count
  }

  /// First line anywhere in the file whose trimmed form starts with `key:`.
  /// Patch keys are namespaced paths, so a single match is unambiguous.
  private func location(of key: String) -> KeyLocation {
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix(key + ":") {
        return KeyLocation(index: index, indent: leadingSpaces(line))
      }
    }
    return KeyLocation()
  }

  private func blockBodyIndex(of block: String, matching key: String) -> Int? {
    let blockLocation = location(of: block)
    guard blockLocation.index >= 0 else { return nil }
    for index in (blockLocation.index + 1)..<lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if leadingSpaces(line) <= blockLocation.indent { break }
      if trimmed.hasPrefix(key + ":") { return index }
    }
    return nil
  }

  /// Quotes are resolved before the trailing-comment scan, so a quoted value
  /// containing `#` survives a round trip.
  private func scalarValue(of line: String) -> String? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let raw = Substring(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    guard let quote = raw.first, quote == "'" || quote == "\"" else {
      if let hash = raw.firstIndex(of: "#") {
        return String(raw[..<hash]).trimmingCharacters(in: .whitespaces)
      }
      return String(raw)
    }

    var result = ""
    var index = raw.index(after: raw.startIndex)
    while index < raw.endIndex {
      let character = raw[index]
      if character == quote {
        let next = raw.index(after: index)
        // YAML escapes a quote inside a single-quoted scalar by doubling it.
        if quote == "'" && next < raw.endIndex && raw[next] == "'" {
          result.append("'")
          index = raw.index(after: next)
          continue
        }
        return result
      }
      result.append(character)
      index = raw.index(after: index)
    }
    return result
  }

  private mutating func insertAfterPatch(_ line: String) {
    let patchLocation = location(of: "patch")
    if patchLocation.index >= 0 {
      lines.insert(line, at: patchLocation.index + 1)
    } else {
      lines.append("patch:")
      lines.append(line)
    }
  }
}
