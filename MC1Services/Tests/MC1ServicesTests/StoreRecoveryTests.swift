import Foundation
@testable import MC1Services
import Testing

/// Covers the file-moving half of `MC1App`'s "Back Up & Reset" recovery. The rule the
/// tests exist to hold: recovery relocates, it never deletes.
@Suite("Store recovery backup")
struct StoreRecoveryTests {
  private func withTemporaryStore(_ body: (URL, FileManager) throws -> Void) throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(path: "StoreRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    try body(root.appending(path: "default.store"), fileManager)
  }

  private func write(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
  }

  @Test
  func `Store file set covers the SQLite trio and the external-storage sidecar`() {
    let storeURL = URL(filePath: "/tmp/Support/default.store")
    let names = PersistenceStore.storeFileURLs(for: storeURL).map(\.lastPathComponent)
    #expect(names == ["default.store", "default.store-wal", "default.store-shm", ".default_SUPPORT"])
  }

  @Test
  func `Default store URL is the one the container actually opens`() {
    // Derived from the same ModelConfiguration, so recovery can never move a different
    // file than the one that failed to open.
    #expect(PersistenceStore.defaultStoreURL.lastPathComponent == "default.store")
  }

  @Test
  func `Every store artefact is moved into a timestamped folder`() throws {
    try withTemporaryStore { storeURL, fileManager in
      let directory = storeURL.deletingLastPathComponent()
      try write("store", to: storeURL)
      try write("wal", to: directory.appending(path: "default.store-wal"))
      try write("shm", to: directory.appending(path: "default.store-shm"))
      let sidecar = directory.appending(path: ".default_SUPPORT", directoryHint: .isDirectory)
      try fileManager.createDirectory(at: sidecar, withIntermediateDirectories: true)
      try write("blob", to: sidecar.appending(path: "blob.bin"))

      let destination = try PersistenceStore.backUpAndClearStore(
        storeURL: storeURL,
        timestamp: Date(timeIntervalSince1970: 1_785_369_600)
      )

      // Nothing left where the failed container was looking...
      for url in PersistenceStore.storeFileURLs(for: storeURL) {
        #expect(!fileManager.fileExists(atPath: url.path(percentEncoded: false)))
      }
      // ...and nothing lost.
      #expect(try String(contentsOf: destination.appending(path: "default.store"), encoding: .utf8) == "store")
      #expect(try String(contentsOf: destination.appending(path: "default.store-wal"), encoding: .utf8) == "wal")
      #expect(try String(contentsOf: destination.appending(path: "default.store-shm"), encoding: .utf8) == "shm")
      #expect(try String(contentsOf: destination.appending(path: ".default_SUPPORT/blob.bin"), encoding: .utf8) == "blob")

      #expect(destination.deletingLastPathComponent().lastPathComponent == PersistenceStore.storeBackupsFolderName)
      #expect(destination.lastPathComponent == "2026-07-30T00-00-00Z")
    }
  }

  @Test
  func `A store with no sidecar files backs up cleanly`() throws {
    try withTemporaryStore { storeURL, fileManager in
      try write("store", to: storeURL)

      let destination = try PersistenceStore.backUpAndClearStore(storeURL: storeURL)

      #expect(fileManager.fileExists(atPath: destination.appending(path: "default.store").path(percentEncoded: false)))
      #expect(!fileManager.fileExists(atPath: storeURL.path(percentEncoded: false)))
    }
  }

  @Test
  func `Two resets in the same second do not overwrite each other`() throws {
    try withTemporaryStore { storeURL, _ in
      let timestamp = Date(timeIntervalSince1970: 1_785_369_600)
      try write("first", to: storeURL)
      let first = try PersistenceStore.backUpAndClearStore(storeURL: storeURL, timestamp: timestamp)

      try write("second", to: storeURL)
      let second = try PersistenceStore.backUpAndClearStore(storeURL: storeURL, timestamp: timestamp)

      #expect(first != second)
      #expect(try String(contentsOf: first.appending(path: "default.store"), encoding: .utf8) == "first")
      #expect(try String(contentsOf: second.appending(path: "default.store"), encoding: .utf8) == "second")
    }
  }

  @Test
  func `The store path is left clear for a fresh container`() throws {
    try withTemporaryStore { storeURL, fileManager in
      try write("not a sqlite database", to: storeURL)

      try PersistenceStore.backUpAndClearStore(storeURL: storeURL)

      #expect(!fileManager.fileExists(atPath: storeURL.path(percentEncoded: false)))
      // The app follows the move with `createContainer()`; the path being clear is the
      // precondition that makes that succeed.
      #expect(fileManager.fileExists(atPath: storeURL.deletingLastPathComponent()
          .appending(path: PersistenceStore.storeBackupsFolderName).path(percentEncoded: false)))
    }
  }
}
