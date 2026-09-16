//
//  Brand.swift
//  Bangke
//

import Foundation

// 身份信息全部来自 Info.plist，其值由 Brand.xcconfig 在构建时展开。
// 这样代码里不出现品牌字面量，换名只需改 Brand.xcconfig。
enum Brand {
  /// 产物名，同时是 Swift 模块名与可执行文件名
  static let productName = infoString("CFBundleName")

  /// 输入源 ID 根，形如 im.bangke.inputmethod.Bangke
  static let inputSourceID = infoString("TISInputSourceID")
  static let connectionName = infoString("InputMethodConnectionName")
  static let codeName = infoString("RimeCodeName")
  static let rimeAppName = infoString("RimeAppName")
  static let configName = infoString("RimeConfigName")

  /// 跟随系统语言本地化：中文系统「蚌壳拼音」，其他「Bangke Pinyin」。
  /// librime 的 distribution_name 也用它，与 Windows 版行为一致。
  static let displayName = infoString("CFBundleDisplayName")

  /// 可见输入源 ID，顺序与 Info.plist 的 tsVisibleInputModeOrderedArrayKey 一致
  static let inputSourceIDs: [String] = {
    let modes = Bundle.main.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [String: Any]
    return modes?["tsVisibleInputModeOrderedArrayKey"] as? [String] ?? []
  }()

  private static func infoString(_ key: String) -> String {
    Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
  }
}
