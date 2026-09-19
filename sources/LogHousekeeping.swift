//
//  LogHousekeeping.swift
//  Bangke
//

import Foundation

/// 运行日志的滚动策略：非今天的日志轮转进 `archive/` 并压缩，归档保留 `retentionDays` 天。
///
/// 放在前端而不是 librime：librime 的 `clean_old_log_files` 只在部署时跑，而且直接删，
/// 拿它换不到「与部署解耦的每日滚动」和可回溯的归档。目录本来就是前端创建并交出去的
/// （`BangkeApp.logDir`），策略跟着所有权走。
enum LogHousekeeping {
  /// 保留期唯一出处。
  static let retentionDays = 7

  private static let archiveDirectoryName = "archive"
  /// 压缩串行化：下一次轮转可能在上一次压缩还没跑完时触发。
  private static let compressionQueue = DispatchQueue(label: "log-compression", qos: .utility)

  /// 保留期的下界，早于它的日志不再保留。
  private static var expiryCutoff: Date {
    Date(timeIntervalSinceNow: -Double(retentionDays) * 24 * 60 * 60)
  }

  /// 轮转（改名，O(1)）+ 派发后台压缩。轮转必须同步完成，理由见 `rotate`。
  static func run(logDir: URL) {
    rotate(logDir: logDir)
    compressionQueue.async { compressAndExpire(logDir: logDir) }
  }

  /// 把非今天的日志挪进 `archive/`，顺带删掉悬空符号链接和已经过期的日志。
  ///
  /// 挪走是为了给 librime 的 `clean_old_log_files` 让路：那个部署任务会删掉所有「文件名
  /// 不含今天日期」的 `*.log`，而它非递归、只收 `.log` 结尾，`archive/` 里的东西它扫不到。
  /// 先挪走，它就没得删，7 天的历史才留得住。
  private static func rotate(logDir: URL) {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil, options: []) else { return }

    let archiveDir = logDir.appendingPathComponent(archiveDirectoryName, isDirectory: true)
    var rotated = 0
    var discarded = 0

    for entry in entries {
      let name = entry.lastPathComponent
      guard !name.hasPrefix(".") else { continue }
      guard let attributes = try? fileManager.attributesOfItem(atPath: entry.path),
            let type = attributes[.type] as? FileAttributeType,
            type == .typeRegular,
            let modified = attributes[.modificationDate] as? Date,
            !Calendar.current.isDateInToday(modified) else { continue }

      // 还有进程开着它就不能动：搬走再压缩会让它把后续日志写进已删除的 inode。
      guard !isOpen(entry) else { continue }

      if modified < expiryCutoff {
        try? fileManager.removeItem(at: entry)
        discarded += 1
        continue
      }
      try? fileManager.createDirectory(at: archiveDir, withIntermediateDirectories: true)
      if (try? fileManager.moveItem(at: entry, to: freeDestination(in: archiveDir, for: name))) != nil {
        rotated += 1
      }
    }

    // 悬空链接放在归档之后扫，这样本轮刚挪走的文件留下的链接同轮就清掉了。
    for entry in entries where attributeType(of: entry) == .typeSymbolicLink {
      if !fileManager.fileExists(atPath: entry.path) {
        try? fileManager.removeItem(at: entry)
      }
    }

    if rotated + discarded > 0 {
      print("LogHousekeeping: archived \(rotated), discarded \(discarded) -> \(archiveDir.path)")
    }
  }

  /// 压缩 `archive/` 里还没压的，并清掉超过保留期的归档。
  static func compressAndExpire(logDir: URL) {
    let fileManager = FileManager.default
    let archiveDir = logDir.appendingPathComponent(archiveDirectoryName, isDirectory: true)
    guard let entries = try? fileManager.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil, options: []) else { return }

    for entry in entries {
      guard let attributes = try? fileManager.attributesOfItem(atPath: entry.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let modified = attributes[.modificationDate] as? Date else { continue }
      if modified < expiryCutoff {
        try? fileManager.removeItem(at: entry)
        continue
      }
      guard entry.pathExtension != "gz" else { continue }
      compress(entry, modifiedAt: modified)
    }
  }

  /// `-n` 不把原名和时间戳写进头：反正我们把它改名成 `<原名>.gz`，头里再存一份只是重复。
  private static func compress(_ file: URL, modifiedAt modified: Date) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    task.arguments = ["-9", "-n", "-f", file.path]
    guard (try? task.run()) != nil else { return }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return }
    // 压缩产物继承原 mtime：保留期按日志年龄算，而不是按压缩时刻算。
    try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path + ".gz")
  }

  /// 还有进程开着这个文件吗？这是唯一能精确回答「它还在被写吗」的办法。
  ///
  /// 不能用 glog 的符号链接来推断：上一个进程留下的链接会一直指着它的文件，拿它当判据
  /// 会把所有该归档的旧日志都放过（然后被 librime 的删除任务吃掉）。链接只在进程重新写
  /// 日志时才改指向，那个时机与轮转时机无关。
  ///
  /// 这里放过的文件会落到 librime 的删除任务手上，而它只保护符号链接指向的文件。生产里
  /// 两者是一致的：这个目录只有两个 glog 实例在写，各自的在用文件就是它符号链接的目标。
  private static func isOpen(_ file: URL) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    task.arguments = ["-t", "--", file.path]
    let output = Pipe()
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return true }
    let openBy = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    if !openBy.isEmpty {
      return true
    }
    // 没匹配到 lsof 返回 1；其它退出码说明它没能回答，保守当作还开着。
    return task.terminationStatus != 1
  }

  /// 同名归档已存在时另起一个名字而不是覆盖：覆盖会和后台正在压缩的同名文件抢同一个路径。
  private static func freeDestination(in directory: URL, for name: String) -> URL {
    var candidate = directory.appendingPathComponent(name)
    var index = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(name).\(index)")
      index += 1
    }
    return candidate
  }

  /// 不跟随符号链接，与 `isDirectory` 那类跟随链接的判断不同——这里要区分的正是链接本身。
  private static func attributeType(of item: URL) -> FileAttributeType? {
    (try? FileManager.default.attributesOfItem(atPath: item.path))?[.type] as? FileAttributeType
  }
}
