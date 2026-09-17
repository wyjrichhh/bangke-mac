//
//  Main.swift
//  Bangke
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

@main
struct BangkeApp {
  static let userDir = if let pwuid = getpwuid(getuid()) {
    URL(fileURLWithFileSystemRepresentation: pwuid.pointee.pw_dir, isDirectory: true, relativeTo: nil).appending(components: "Library", "Rime")
  } else {
    try! FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Rime", isDirectory: true)
  }
  // 运行中的 bundle 路径就是安装位置，不必写死 /Library/Input Methods/<name>.app
  static let appDir = Bundle.main.bundleURL
  /// 文件名意义上的产物名（BangkePinyin）。不能用 Brand.productName：那是
  /// CFBundleName，会随系统语言被 InfoPlist.xcstrings 本地化成「蚌壳拼音」，
  /// 而安装脚本 (package/dist-scripts) 写死的是 ASCII 名 —— 两边必须是同一个
  /// 目录，否则插件的日志会被写到没人找得到的地方。
  static let bundleName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
  // Use ~/Library/Logs/<product>/ instead of TMPDIR so that the log files are
  // visible from a normal user shell (the IMK sandbox redirects TMPDIR to a
  // location that is not reachable outside the sandbox, which makes debugging
  // very hard — see https://github.com/rime/squirrel/issues for context).
  static let logDir = if let pwuid = getpwuid(getuid()) {
    URL(fileURLWithFileSystemRepresentation: pwuid.pointee.pw_dir, isDirectory: true, relativeTo: nil).appending(components: "Library", "Logs", bundleName)
  } else {
    try! FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Logs/\(bundleName)", isDirectory: true)
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func main() {
    let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee

    let handled = autoreleasepool {
      let installer = BangkeInstaller()
      let args = CommandLine.arguments
      if args.count > 1 {
        switch args[1] {
        case "--quit":
          let bundleId = Bundle.main.bundleIdentifier!
          let runningBangkes = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
          runningBangkes.forEach { $0.terminate() }
          return true
        case "--reload":
          // Bangke is a background app, and AppKit suspends distributed-notification delivery to inactive apps;
          // deliverImmediately is required for these notifications to reach Bangke while it stays in the background
          DistributedNotificationCenter.default().postNotificationName(.init("BangkeReloadNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          return true
        case "--register-input-source", "--install":
          installer.register()
          return true
        case "--enable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { BangkeInstaller.InputMode.from(inputSourceID: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.enable(modes: modes)
              return true
            }
          }
          installer.enable()
          return true
        case "--disable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { BangkeInstaller.InputMode.from(inputSourceID: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.disable(modes: modes)
              return true
            }
          }
          installer.disable()
          return true
        case "--select-input-source":
          if args.count > 2, let mode = BangkeInstaller.InputMode.from(inputSourceID: args[2]) {
            installer.select(mode: mode)
          } else {
            installer.select()
          }
          return true
        case "--install-custom-config":
          // postinstall uses this to lay down a shipped *.custom.yaml without
          // discarding the values the user picked in the settings window.
          guard args.count > 3 else {
            print("usage: --install-custom-config <factory> <destination>")
            exit(2)
          }
          let installed = BangkeSettings.installCustomConfig(
            factory: URL(fileURLWithPath: args[2]),
            destination: URL(fileURLWithPath: args[3]))
          if !installed {
            exit(1)
          }
          return true
        case "--build":
          BangkeApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_update", comment: ""))
          var builderTraits = RimeTraits.rimeStructInit()
          builderTraits.setCString("rime.bangke-builder", to: \.app_name)
          rimeAPI.setup(&builderTraits)
          rimeAPI.deployer_initialize(nil)
          _ = rimeAPI.deploy()
          return true
        case "--sync":
          DistributedNotificationCenter.default().postNotificationName(.init("BangkeSyncNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          return true
        case "--ascii":
          DistributedNotificationCenter.default().postNotificationName(.init("BangkeToggleASCIIModeNotification"), object: "ascii", userInfo: nil, deliverImmediately: true)
          return true
        case "--nascii":
          DistributedNotificationCenter.default().postNotificationName(.init("BangkeToggleASCIIModeNotification"), object: "nascii", userInfo: nil, deliverImmediately: true)
          return true
        case "--getascii":
          var responseReceived = false
          var asciiStatus = ""
          let observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("BangkeASCIIModeResponse"),
            object: nil,
            queue: .main
          ) { notification in
            if let status = notification.object as? String {
              asciiStatus = status
              responseReceived = true
            }
          }
          DistributedNotificationCenter.default().postNotificationName(.init("BangkeGetASCIIModeNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          let timeout = Date().addingTimeInterval(2.0)
          while !responseReceived && Date() < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
          }
          DistributedNotificationCenter.default().removeObserver(observer)
          if responseReceived {
            print(asciiStatus)
          } else {
            print("nascii")
          }
          return true
        case "--help":
          print(helpDoc)
          return true
        default:
          break
        }
      }
      return false
    }
    if handled {
      return
    }

    autoreleasepool {
      let main = Bundle.main
      let connectionName = main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String
      _ = IMKServer(name: connectionName, bundleIdentifier: main.bundleIdentifier!)
      let app = NSApplication.shared
      let delegate = BangkeApplicationDelegate()
      app.delegate = delegate
      app.setActivationPolicy(.accessory)

      // OpenCC uses relative dictionary paths from SharedSupport.
      FileManager.default.changeCurrentDirectoryPath(main.sharedSupportPath!)

      if NSApp.bangkeAppDelegate.problematicLaunchDetected() {
        print("Problematic launch detected!")
        let args = ["Problematic launch detected! \(Brand.productName) may be suffering a crash due to improper configuration. Revert previous modifications to see if the problem recurs."]
        let task = Process()
        task.executableURL = "/usr/bin/say".withCString { dir in
          URL(fileURLWithFileSystemRepresentation: dir, isDirectory: false, relativeTo: nil)
        }
        task.arguments = args
        try? task.run()
      } else {
        NSApp.bangkeAppDelegate.setupRime()
        NSApp.bangkeAppDelegate.startRime(fullCheck: false)
        NSApp.bangkeAppDelegate.loadSettings()
        print("\(Brand.productName) reporting!")
      }

      app.run()
      print("\(Brand.productName) is quitting...")
      rimeAPI.finalize()
    }
    return
  }

  static let helpDoc = """
Supported arguments:
Perform actions:
  --quit                     quit all \(Brand.productName) process
  --reload                   deploy
  --sync                     sync user data
  --build                    build all schemas in current directory
  --install-custom-config <factory> <destination>
                             write a shipped patch file, keeping user values
  --ascii                    turn on ASCII mode
  --nascii                   turn off ASCII mode
  --getascii                 get current ASCII mode status
Install \(Brand.productName):
  --install, --register-input-source    register input source
  --enable-input-source [source id...]  input source list optional
  --disable-input-source [source id...] input source list optional
  --select-input-source [source id]     input source optional
"""
}
