import Foundation
import os
import SwiftData

/// Failures raised while relocating an unopenable store out of the way.
public enum StoreRecoveryError: Error, Sendable {
  /// A store file could not be moved. Carries the file name and the underlying reason.
  case moveFailed(file: String, reason: String)
  /// The timestamped backup folder could not be created.
  case backupFolderCreationFailed(String)
}

extension StoreRecoveryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .moveFailed(file, reason): "Could not move \(file): \(reason)"
    case let .backupFolderCreationFailed(reason): "Could not create the backup folder: \(reason)"
    }
  }
}

public extension PersistenceStore {
  private static let recoveryLogger = Logger(subsystem: "com.mc1", category: "StoreRecovery")

  /// Subfolder of Application Support that holds relocated stores.
  static let storeBackupsFolderName = "StoreBackups"

  /// The on-disk location `createContainer(inMemory: false)` opens.
  ///
  /// Derived from the very same `ModelConfiguration` the container uses rather than by
  /// re-deriving "Application Support/default.store" by hand, so recovery can never move
  /// a different file than the one that failed to open.
  static var defaultStoreURL: URL {
    ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, allowsSave: true).url
  }

  /// Every on-disk artefact belonging to `storeURL`, in the order they should be moved.
  ///
  /// The SQLite trio plus Core Data's external-binary sidecar directory
  /// (`.default_SUPPORT`, where `@Attribute(.externalStorage)` blobs such as
  /// `Message.linkPreviewImageData` live). The sidecar travels with the store: leaving it
  /// behind would both orphan its contents forever and make the backup non-restorable.
  /// Entries that do not exist are skipped by the caller.
  static func storeFileURLs(for storeURL: URL) -> [URL] {
    let directory = storeURL.deletingLastPathComponent()
    let name = storeURL.lastPathComponent
    let sidecar = ".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT"
    return [
      storeURL,
      directory.appending(path: "\(name)-wal"),
      directory.appending(path: "\(name)-shm"),
      directory.appending(path: sidecar)
    ]
  }

  /// Moves the current store aside into `StoreBackups/<timestamp>/` so a fresh container
  /// can be created, and returns the folder the files landed in.
  ///
  /// Nothing is deleted — this is the "reset" half of the user-confirmed *Back Up & Reset*
  /// recovery in `MC1App`, and the whole point is that a store which failed migration stays
  /// recoverable by hand (or by a future repair tool) afterwards. Missing files are skipped:
  /// a store with no `-wal`/`-shm` is normal after a clean shutdown.
  ///
  /// - Parameters:
  ///   - storeURL: Store to relocate. Defaults to the app's real store.
  ///   - timestamp: Names the destination folder. Injectable for tests.
  /// - Returns: The folder the store files were moved into.
  @discardableResult
  static func backUpAndClearStore(
    storeURL: URL = defaultStoreURL,
    timestamp: Date = Date(),
    fileManager: FileManager = .default
  ) throws -> URL {
    let root = storeURL.deletingLastPathComponent().appending(path: storeBackupsFolderName, directoryHint: .isDirectory)
    let destination = uniqueBackupFolderURL(in: root, timestamp: timestamp, fileManager: fileManager)

    do {
      try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    } catch {
      throw StoreRecoveryError.backupFolderCreationFailed(error.localizedDescription)
    }

    for source in storeFileURLs(for: storeURL) {
      guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
      do {
        try fileManager.moveItem(at: source, to: destination.appending(path: source.lastPathComponent))
      } catch {
        throw StoreRecoveryError.moveFailed(file: source.lastPathComponent, reason: error.localizedDescription)
      }
    }

    recoveryLogger.notice("Store relocated to \(destination.lastPathComponent, privacy: .public)")
    return destination
  }

  /// `StoreBackups/2026-07-30T14-05-33Z`, disambiguated with `-2`, `-3`… if a folder of that
  /// name already exists (two resets inside the same second, or a restored backup folder).
  /// Colons are avoided in the name: they are legal in APFS paths but Finder renders them
  /// as slashes, which makes the folder confusing to hand off to a user in support.
  private static func uniqueBackupFolderURL(in root: URL, timestamp: Date, fileManager: FileManager) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
    let base = formatter.string(from: timestamp)

    var candidate = root.appending(path: base, directoryHint: .isDirectory)
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
      candidate = root.appending(path: "\(base)-\(suffix)", directoryHint: .isDirectory)
      suffix += 1
    }
    return candidate
  }
}
