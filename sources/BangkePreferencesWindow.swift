//
//  BangkePreferencesWindow.swift
//  Bangke
//

import AppKit
import SwiftUI

final class BangkeSettingsModel: ObservableObject {
  @Published var settings: BangkeSettings
  @Published var errorMessage: String?

  let colorSchemes: [String]
  let fontFamilies: [String]

  init() {
    let loaded = BangkeSettings.load()
    settings = loaded

    var schemes = BangkeSettings.colorSchemeNames()
    if !schemes.contains("native") {
      schemes.insert("native", at: 0)
    }
    colorSchemes = schemes

    var families = NSFontManager.shared.availableFontFamilies.sorted()
    if !loaded.appearance.fontFace.isEmpty, !families.contains(loaded.appearance.fontFace) {
      families.insert(loaded.appearance.fontFace, at: 0)
    }
    fontFamilies = families
  }

  func restoreDefaults() {
    settings = BangkeSettings()
  }
}

// MARK: - Window

final class BangkePreferencesWindowController: NSWindowController, NSWindowDelegate {
  private let model = BangkeSettingsModel()

  convenience init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = NSLocalizedString("Bangke Settings", comment: "Preferences window title")
    self.init(window: window)
    window.delegate = self
    window.contentView = NSHostingView(rootView: BangkePreferencesView(model: model, onClose: { [weak self] in
      self?.close()
    }))
    window.center()
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.bangkeAppDelegate.preferencesDidClose()
  }
}

// MARK: - Root view

struct BangkePreferencesView: View {
  @ObservedObject var model: BangkeSettingsModel
  var onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      preview
      Divider()
      tabs
      Divider()
      footer
    }
    .frame(minWidth: 620, minHeight: 660)
    .alert("Could not save settings", isPresented: isShowingError) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private var isShowingError: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  private var preview: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Preview").font(.caption).foregroundStyle(.secondary)
      // An HStack rather than maxWidth: .infinity — the canvas must keep its
      // intrinsic size, or the panel sits in a corner of an oversized strip.
      HStack(spacing: 0) {
        BangkePreviewRepresentable(settings: model.settings)
        Spacer(minLength: 0)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .underPageBackgroundColor))
  }

  private var tabs: some View {
    TabView {
      AppearanceSettingsTab(settings: $model.settings.appearance,
                            colorSchemes: model.colorSchemes,
                            fontFamilies: model.fontFamilies)
        .tabItem { Text("Appearance") }
      BehaviorSettingsTab(settings: $model.settings.behavior)
        .tabItem { Text("Behavior") }
      AIPredictSettingsTab(settings: $model.settings.aiPredict)
        .tabItem { Text("AI Prediction") }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      Button("Restore Defaults") { model.restoreDefaults() }
      Button("Open User Folder") { NSApp.bangkeAppDelegate.openRimeFolder() }
      Button("Open Logs") { NSApp.bangkeAppDelegate.openLogFolder() }
      Spacer()
      Button("Cancel") { onClose() }
        .keyboardShortcut(.cancelAction)
      Button("Save and Apply") { save() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(16)
  }

  private func save() {
    do {
      let needsDeployment = try model.settings.save()
      if needsDeployment {
        // Page size and the AI block feed schema compilation, which only a full
        // maintenance pass picks up.
        NSApp.bangkeAppDelegate.deploy()
      } else {
        NSApp.bangkeAppDelegate.reloadSettings()
      }
      onClose()
    } catch {
      model.errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Appearance

struct AppearanceSettingsTab: View {
  @Binding var settings: BangkeSettings.Appearance
  let colorSchemes: [String]
  let fontFamilies: [String]

  var body: some View {
    Form {
      Section("Color") {
        Picker("Color scheme", selection: $settings.colorScheme) {
          ForEach(colorSchemes, id: \.self) { Text($0).tag($0) }
        }
        Picker("Dark color scheme", selection: $settings.colorSchemeDark) {
          Text("Follow light scheme").tag("")
          ForEach(colorSchemes, id: \.self) { Text($0).tag($0) }
        }
        SettingsSlider(title: "Background opacity", value: $settings.alpha, range: 0...1, step: 0.05)
      }

      Section("Font") {
        Picker("Font", selection: $settings.fontFace) {
          ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
        }
        SettingsSlider(title: "Font size", value: $settings.fontPoint, range: 8...48, step: 1)
      }

      Section("Layout") {
        Picker("Candidate list", selection: $settings.candidateListLayout) {
          Text("Stacked").tag("stacked")
          Text("Linear").tag("linear")
        }
        Picker("Text orientation", selection: $settings.textOrientation) {
          Text("Horizontal").tag("horizontal")
          Text("Vertical").tag("vertical")
        }
        SettingsSlider(title: "Corner radius", value: $settings.cornerRadius, range: 0...30, step: 1)
        SettingsSlider(title: "Highlight corner radius", value: $settings.hilitedCornerRadius, range: 0...30, step: 1)
        SettingsSlider(title: "Line spacing", value: $settings.lineSpacing, range: -10...30, step: 1)
        SettingsSlider(title: "Preedit spacing", value: $settings.spacing, range: -10...30, step: 1)
        SettingsSlider(title: "Shadow size", value: $settings.shadowSize, range: 0...30, step: 1)
        SettingsSlider(title: "Border height", value: $settings.borderHeight, range: -10...20, step: 1)
        SettingsSlider(title: "Border width", value: $settings.borderWidth, range: -10...20, step: 1)
      }

      Section("Display") {
        Toggle("Show preedit in the input field", isOn: $settings.inlinePreedit)
        Toggle("Show selected candidate in the input field", isOn: $settings.inlineCandidate)
        Toggle("Translucent background", isOn: $settings.translucency)
        Toggle("Stack transparent colors", isOn: $settings.mutualExclusive)
        Toggle("Keep panel near the screen edge", isOn: $settings.memorizeSize)
        Toggle("Show paging arrows", isOn: $settings.showPaging)
      }

      Section("Format") {
        TextField("Candidate format", text: $settings.candidateFormat)
        Text("Use [label], [candidate] and [comment] as placeholders.")
          .font(.caption).foregroundStyle(.secondary)
        Picker("Status messages", selection: $settings.statusMessageType) {
          Text("Long").tag("long")
          Text("Short").tag("short")
          Text("Mixed").tag("mix")
        }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Behavior

struct BehaviorSettingsTab: View {
  @Binding var settings: BangkeSettings.Behavior

  private let shiftActions = ["commit_code", "commit_text", "inline_ascii", "clear", "noop"]

  var body: some View {
    Form {
      Section("Menu Bar") {
        Toggle("Show status icon in the menu bar", isOn: $settings.showStatusIcon)
        Picker("Notifications", selection: $settings.notificationsWhen) {
          Text("Never").tag("never")
          Text("When appropriate").tag("appropriate")
          Text("Always").tag("always")
        }
      }

      Section("Typing") {
        SettingsSlider(title: "Candidates per page", value: $settings.pageSize, range: 1...20, step: 1)
        SettingsSlider(title: "Chord duration", value: $settings.chordDuration, range: 0...1, step: 0.01)
        Picker("Left Shift", selection: $settings.shiftLeftAction) {
          ForEach(shiftActions, id: \.self) { Text($0).tag($0) }
        }
        Picker("Right Shift", selection: $settings.shiftRightAction) {
          ForEach(shiftActions, id: \.self) { Text($0).tag($0) }
        }
      }

      Section("Keyboard Layout") {
        TextField("Layout", text: $settings.keyboardLayout)
        Text("Use last, default, or a layout name such as com.apple.keylayout.ABC.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - AI prediction

struct AIPredictSettingsTab: View {
  @Binding var settings: BangkeSettings.AIPredict

  var body: some View {
    Form {
      Section {
        Toggle("Enable AI prediction", isOn: $settings.enabled)
        SettingsSlider(title: "Candidate position", value: $settings.targetIndex, range: 0...20, step: 1)
        Text("AI candidates must sit below the search range to appear.")
          .font(.caption).foregroundStyle(.secondary)
        SettingsSlider(title: "Minimum input length", value: $settings.minInputLength, range: 1...40, step: 1)
        SettingsSlider(title: "Minimum characters", value: $settings.minHanzi, range: 1...10, step: 1)
        SettingsSlider(title: "Debounce (ms)", value: $settings.debounceMs, range: 0...2000, step: 20)
        Text("Applies to every input method that has AI prediction wired in.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Advanced") {
        SettingsSlider(title: "Search range", value: $settings.searchRange, range: 1...50, step: 1)
        SettingsSlider(title: "Context window", value: $settings.contextWindowSize, range: 1...50, step: 1)
        SettingsSlider(title: "Minimum context length", value: $settings.minContextPromptLength, range: 1...20, step: 1)
        SettingsSlider(title: "Max tokens", value: $settings.maxTokens, range: 8...512, step: 8)
        SettingsSlider(title: "Quality", value: $settings.quality, range: -1...100, step: 1)
        Picker("Device", selection: $settings.device) {
          Text("CPU").tag("cpu")
        }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Rows

struct SettingsSlider: View {
  let title: LocalizedStringKey
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 8) {
        Slider(value: $value, in: range, step: step)
        Text(displayValue)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 40, alignment: .trailing)
      }
    }
  }

  private var displayValue: String {
    step >= 1 ? String(Int(value.rounded())) : String(format: "%.2f", value)
  }
}

extension SettingsSlider {
  init(title: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>, step: Int) {
    self.init(title: title,
              value: Binding(get: { Double(value.wrappedValue) },
                             set: { value.wrappedValue = Int($0.rounded()) }),
              range: Double(range.lowerBound)...Double(range.upperBound),
              step: Double(step))
  }
}
