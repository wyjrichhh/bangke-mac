//
//  InputSource.swift
//  Bangke
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

final class BangkeInstaller {
  // ID 不在这里写死：顺序即 Info.plist 的 tsVisibleInputModeOrderedArrayKey。
  enum InputMode: CaseIterable {
    static let primary = Self.hans
    case hans
    case hant

    var inputSourceID: String {
      let ids = Brand.inputSourceIDs
      let index = Self.allCases.firstIndex(of: self)!
      return index < ids.count ? ids[index] : ""
    }

    static func from(inputSourceID: String) -> InputMode? {
      allCases.first { $0.inputSourceID == inputSourceID }
    }
  }
  private lazy var inputSources: [String: TISInputSource] = {
    var inputSources = [String: TISInputSource]()
    var matchingSources = [InputMode: TISInputSource]()
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    for inputSource in sourceList {
      let sourceIDRef = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
      guard let sourceID = unsafeBitCast(sourceIDRef, to: CFString?.self) as String? else { continue }
      inputSources[sourceID] = inputSource
    }
    return inputSources
  }()

  func enabledModes() -> [InputMode] {
    var enabledModes = Set<InputMode>()
    for (mode, inputSource) in getInputSource(modes: InputMode.allCases) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        enabledModes.insert(mode)
      }
      if enabledModes.count == InputMode.allCases.count {
        break
      }
    }
    return Array(enabledModes)
  }

  func register() {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty {
      print("User already registered \(Brand.productName) method(s): \(enabledInputModes.map { $0.inputSourceID })")
      return
    }
    TISRegisterInputSource(BangkeApp.appDir as CFURL)
    print("Registered input source from \(BangkeApp.appDir)")
  }

  func enable(modes: [InputMode] = []) {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty && modes.isEmpty {
      print("User already enabled \(Brand.productName) method(s): \(enabledInputModes.map { $0.inputSourceID })")
      // Preserve manually enabled input modes.
      return
    }
    let modesToEnable = modes.isEmpty ? [.primary] : modes
    for (mode, inputSource) in getInputSource(modes: modesToEnable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), !enabled {
        let error = TISEnableInputSource(inputSource)
        print("Enable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.inputSourceID)")
      }
    }
  }

  func select(mode: InputMode? = nil) {
    let enabledInputModes = enabledModes()
    let modeToSelect = mode ?? .primary
    if !enabledInputModes.contains(modeToSelect) {
      if mode != nil {
        enable(modes: [modeToSelect])
      } else {
        print("Default method not enabled yet: \(modeToSelect.inputSourceID)")
        return
      }
    }
    for (mode, inputSource) in getInputSource(modes: [modeToSelect]) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled),
         let selectable = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelectCapable),
         let selected = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelected),
         enabled && selectable && !selected {
        let error = TISSelectInputSource(inputSource)
        print("Selection \(error == noErr ? "succeeds" : "fails") for input source: \(mode.inputSourceID)")
      } else {
        print("Failed to select \(mode.inputSourceID)")
      }
    }
  }

  static func currentInputSourceID() -> String? {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    return unsafeBitCast(idRef, to: CFString?.self) as String?
  }

  /// Leave registration and enabled-mode preferences intact during deployment.
  func prepareDeployment() -> Bool {
    guard let current = Self.currentInputSourceID(),
          current == Brand.inputSourceID || Brand.inputSourceIDs.contains(current) else { return true }
    let enabledSources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    for source in enabledSources {
      guard let typeRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
            let type = unsafeBitCast(typeRef, to: CFString?.self),
            type == kTISTypeKeyboardLayout,
            getBool(for: source, key: kTISPropertyInputSourceIsSelectCapable) == true else { continue }
      let result = TISSelectInputSource(source)
      if result == noErr { return true }
      print("Cannot select a keyboard layout for deployment: \(result)")
    }
    print("No selectable keyboard layout is available for deployment.")
    return false
  }

  func disable(modes: [InputMode] = []) {
    let modesToDisable = modes.isEmpty ? InputMode.allCases : modes
    for (mode, inputSource) in getInputSource(modes: modesToDisable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        let error = TISDisableInputSource(inputSource)
        print("Disable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.inputSourceID)")
      }
    }
  }

  private func getInputSource(modes: [InputMode]) -> [InputMode: TISInputSource] {
    var matchingSources = [InputMode: TISInputSource]()
    for mode in modes {
      if let inputSource = inputSources[mode.inputSourceID] {
        matchingSources[mode] = inputSource
      }
    }
    return matchingSources
  }

  private func getBool(for inputSource: TISInputSource, key: CFString!) -> Bool? {
    let enabledRef = TISGetInputSourceProperty(inputSource, key)
    guard let enabled = unsafeBitCast(enabledRef, to: CFBoolean?.self) else { return nil }
    return CFBooleanGetValue(enabled)
  }
}
