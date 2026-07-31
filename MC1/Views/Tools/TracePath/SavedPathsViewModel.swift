import MC1Services
import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "SavedPaths")

@Observable
@MainActor
final class SavedPathsViewModel {
  // MARK: - State

  var savedPaths: [SavedTracePathDTO] = []
  var isLoading = false
  var errorMessage: String?

  // MARK: - Dependencies

  private var dataStoreProvider: @MainActor () -> PersistenceStore? = { nil }
  private var connectedDeviceProvider: @MainActor () -> DeviceDTO? = { nil }

  // MARK: - Configuration

  /// Each provider is read live at its point of use; a provider returning
  /// `nil` mirrors a disconnected state, so unconfigured calls are no-ops.
  func configure(
    dataStore: @escaping @MainActor () -> PersistenceStore?,
    connectedDevice: @escaping @MainActor () -> DeviceDTO?
  ) {
    dataStoreProvider = dataStore
    connectedDeviceProvider = connectedDevice
  }

  // MARK: - Data Loading

  func loadSavedPaths() async {
    guard let radioID = connectedDeviceProvider()?.radioID,
          let dataStore = dataStoreProvider() else { return }

    isLoading = true
    errorMessage = nil

    do {
      // Benchmark runs are persisted as trace paths in this same table, but their home is
      // the Benchmark history screen: renaming one here strips the prefix that keeps it in
      // history, and deleting one here erases a measurement the user cannot re-take.
      savedPaths = try await dataStore.fetchSavedTracePaths(radioID: radioID)
        .filter { !BenchmarkNaming.isBenchmarkPath($0.name) }
      logger.info("Loaded \(self.savedPaths.count) saved paths")
    } catch {
      logger.error("Failed to load saved paths: \(error.localizedDescription)")
      errorMessage = L10n.Tools.Tools.SavedPaths.loadFailed
    }

    isLoading = false
  }

  // MARK: - Actions

  func renamePath(_ path: SavedTracePathDTO, to newName: String) async {
    guard let dataStore = dataStoreProvider() else { return }

    do {
      try await dataStore.updateSavedTracePathName(id: path.id, name: newName)
      await loadSavedPaths()
    } catch {
      logger.error("Failed to rename path: \(error.localizedDescription)")
      errorMessage = L10n.Tools.Tools.SavedPaths.renameFailed
    }
  }

  func deletePath(_ path: SavedTracePathDTO) async {
    guard let dataStore = dataStoreProvider() else { return }

    do {
      try await dataStore.deleteSavedTracePath(id: path.id)
      savedPaths.removeAll { $0.id == path.id }
      logger.info("Deleted saved path: \(path.name)")
    } catch {
      logger.error("Failed to delete path: \(error.localizedDescription)")
      errorMessage = L10n.Tools.Tools.SavedPaths.deleteFailed
    }
  }
}
