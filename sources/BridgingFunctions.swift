//
//  BridgingFunctions.swift
//  Bangke
//
//  Created by Leo Liu on 5/11/24.
//

import Foundation

extension URL {
  /// Path as the filesystem spells it. `URL.path()` percent-encodes anything
  /// non-ASCII, so handing it to a C API asks for a directory literally named
  /// `%E8%9A%8C…` — which is how a localized log directory stayed broken and
  /// silent. Use this for every path that crosses into C.
  var fileSystemPath: String {
    path(percentEncoded: false)
  }
}

protocol DataSizeable {
  // swiftlint:disable:next identifier_name
  var data_size: Int32 { get set }
}

extension RimeContext_stdbool: DataSizeable {}
extension RimeTraits: DataSizeable {}
extension RimeCommit: DataSizeable {}
extension RimeStatus_stdbool: DataSizeable {}
extension RimeModule: DataSizeable {}

extension DataSizeable {
  static func rimeStructInit() -> Self {
    let valuePointer = UnsafeMutablePointer<Self>.allocate(capacity: 1)
    memset(valuePointer, 0, MemoryLayout<Self>.size)
    var value = valuePointer.move()
    valuePointer.deallocate()
    // Every DataSizeable declares `data_size` as Int32, so this is 4. Measuring
    // the key path itself (`MemoryLayout.size(ofValue: \Self.data_size)`) yields
    // 8 and under-reports by four bytes — harmless for today's structs, since
    // their last field still lands inside the reported span, but a field added
    // at the end would be silently treated as "not provided".
    value.data_size = Int32(MemoryLayout<Self>.size - MemoryLayout<Int32>.size)
    return value
  }

  mutating func setCString(_ swiftString: String, to keypath: WritableKeyPath<Self, UnsafePointer<CChar>?>) {
    swiftString.withCString { cStr in
      // Rime traits keep C string pointers after this closure returns.
      let mutableCStr = strdup(cStr)
      if let existing = self[keyPath: keypath] {
        free(UnsafeMutableRawPointer(mutating: existing))
      }
      self[keyPath: keypath] = UnsafePointer(mutableCStr)
    }
  }
}

infix operator ?= : AssignmentPrecedence
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T, right: T?) {
  if let right = right {
    left = right
  }
}
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T?, right: T?) {
  if let right = right {
    left = right
  }
}

extension NSRange {
  static let empty = NSRange(location: NSNotFound, length: 0)
}

extension NSPoint {
  static func += (lhs: inout Self, rhs: Self) {
    lhs.x += rhs.x
    lhs.y += rhs.y
  }
  static func - (lhs: Self, rhs: Self) -> Self {
    Self.init(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
  }
  static func -= (lhs: inout Self, rhs: Self) {
    lhs.x -= rhs.x
    lhs.y -= rhs.y
  }
  static func * (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x * rhs, y: lhs.y * rhs)
  }
  static func / (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x / rhs, y: lhs.y / rhs)
  }
  var length: CGFloat {
    sqrt(pow(self.x, 2) + pow(self.y, 2))
  }
}
