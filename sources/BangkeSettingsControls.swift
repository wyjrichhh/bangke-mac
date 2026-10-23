import AppKit
import SwiftUI

func choices(_ options: [(String, String)]) -> [(String, String)] {
  options.map { ($0.0, NSLocalizedString($0.1, comment: "")) }
}

struct SettingsForm<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) { content }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }
  }
}

struct SettingsSection<Content: View>: View {
  var title: LocalizedStringKey
  @ViewBuilder var content: Content

  init(_ title: LocalizedStringKey = "", @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color(nsColor: BangkePalette.color(.muted)))
      VStack(alignment: .leading, spacing: 20) {
        content
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: BangkePalette.color(.card)), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: BangkePalette.color(.line)).opacity(0.35)))
    }
  }
}

struct SettingsChoice: View {
  let title: LocalizedStringKey
  @Binding var selection: String
  let options: [(String, String)]
  @State private var expanded = false
  @State private var active = 0
  @State private var keyboardMonitor: Any?

  init(_ title: LocalizedStringKey, selection: Binding<String>, options: [(String, String)]) {
    self.title = title
    self._selection = selection
    self.options = options
  }

  var body: some View {
    SettingsRow {
      Button {
        active = options.firstIndex(where: { $0.0 == selection }) ?? 0
        expanded.toggle()
      } label: {
        Text(options.first(where: { $0.0 == selection })?.1 ?? selection)
          .lineLimit(1).truncationMode(.tail)
          .frame(width: 164, height: 34)
          .padding(.horizontal, 28)
          .background(Color(nsColor: BangkePalette.color(.field)), in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: BangkePalette.color(.line)).opacity(0.5)))
          .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down").font(.caption2).padding(.trailing, 10)
          }
      }
      .buttonStyle(.plain)
      .popover(isPresented: $expanded, arrowEdge: .bottom) {
        ScrollViewReader { reader in
          ScrollView {
            VStack(spacing: 0) {
              ForEach(options.indices, id: \.self) { index in
                Button {
                  selection = options[index].0
                  expanded = false
                } label: {
                  Text(options[index].1)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .padding(.horizontal, 12)
                    .foregroundStyle(Color(nsColor: BangkePalette.color(index == active ? .onAccent : .ink)))
                    .background(Color(nsColor: BangkePalette.color(index == active ? .accent : .field)))
                }
                .buttonStyle(.plain)
                .onHover { if $0 { active = index } }
                .id(index)
              }
            }
          }
          .frame(width: 220, height: CGFloat(min(options.count, 10) * 32))
          .background(Color(nsColor: BangkePalette.color(.field)))
          .onAppear {
            reader.scrollTo(active, anchor: .center)
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
              switch event.keyCode {
              case 125: active = min(options.count - 1, active + 1)
              case 126: active = max(0, active - 1)
              case 36, 76:
                if options.indices.contains(active) { selection = options[active].0 }
                expanded = false
              case 53: expanded = false
              default: return event
              }
              return nil
            }
          }
          .onChange(of: active) { reader.scrollTo($0) }
          .onDisappear {
            if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
            keyboardMonitor = nil
          }

        }
      }
    } label: {
      Text(title)
    }
  }
}

struct SettingsRow<Label: View, Content: View>: View {
  @ViewBuilder var content: Content
  @ViewBuilder var label: Label

  var body: some View {
    HStack(spacing: 18) {
      label.frame(maxWidth: .infinity, alignment: .leading)
      content.layoutPriority(1)
    }
    .frame(maxWidth: .infinity, minHeight: 34)
  }
}

struct SettingsButtonStyle: ButtonStyle {
  var primary = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium))
      .padding(.horizontal, 18).padding(.vertical, 9)
      .foregroundStyle(Color(nsColor: BangkePalette.color(primary ? .onAccent : .ink)))
      .background(Color(nsColor: BangkePalette.color(primary ? .accent : .field)),
                  in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: BangkePalette.color(.line)).opacity(0.4)))
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}
