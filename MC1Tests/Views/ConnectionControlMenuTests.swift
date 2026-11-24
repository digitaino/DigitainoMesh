import Foundation
@testable import MC1
@testable import MC1Services
import SwiftUI
import Testing
import UIKit

@Suite("Connection control menu", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ConnectionControlMenuTests {
  private enum Layout {
    static let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
  }

  /// The fork's radio pill (`RadioStatusControl`) replaces upstream's `BLEStatusIndicatorView`.
  /// Its tap is a primary action (the signal table or the device picker), so the menu opens
  /// only on a sustained press, which a hosted test cannot drive. This checks what the pill
  /// exports during a recovery and what its Stop Reconnecting item does.
  @Test(arguments: [false, true])
  func `radio pill exports the recovering radio and its stop ends the recovery`(accessibleSize: Bool) async throws {
    let env = try await ConnectionLinkSwitchHarness.make()
    var host: MenuHost?
    do {
      let original = try #require(env.manager.currentConnection)
      let targetName = "Mountain Rescue Operations Relay 27"
      env.manager.persistConnection(deviceID: env.device.id, radioID: env.device.radioID, deviceName: targetName)
      await env.bluetooth.simulateAutoReconnecting(deviceID: env.device.id)
      try await waitUntil("physical loss must publish a recovery activity") {
        env.manager.currentConnection == nil && env.manager.connectionActivity?.phase == .reconnecting
      }
      let activity = try #require(env.manager.connectionActivity)
      #expect(activity.requestID == original.requestID)
      #expect(activity.targetName == targetName)
      #expect(activity.stopTitle == L10n.Settings.BleStatus.stopReconnecting)
      #expect(activity.accessibilityValue.contains(targetName))

      let mounted = try MenuHost(app: env.appState, accessibleSize: accessibleSize)
      host = mounted
      let label = L10n.Settings.BleStatus.accessibilityLabel
      try await waitUntil("production toolbar must export target and status: \(mounted.describe())") {
        mounted.nodes(in: [mounted.window]).contains { $0.label == label && $0.value == activity.accessibilityValue }
      }
      let controls = mounted.nodes(in: [mounted.window]).filter { $0.label == label && $0.value == activity.accessibilityValue }
      #expect(controls.count == 1, "\(mounted.describe())")
      let control = try #require(controls.first)
      #expect(control.hasWindowContainedAXFrame)
      Attachment.record(Data(mounted.describe().utf8), named: "connection-menu-accessibility-tree.txt")

      // What the menu's Stop Reconnecting item calls.
      await env.appState.disconnect(requestID: activity.requestID, reason: .statusMenuDisconnectTap)
      try await waitUntil("stopping the request must end the recovery") {
        env.manager.connectionActivity == nil
      }
    } catch {
      host?.close()
      await env.close()
      throw error
    }
    host?.close()
    await env.close()
  }

  @MainActor
  private final class MenuHost {
    let window: UIWindow
    private let scene: UIWindowScene
    private let previousKeyWindow: UIWindow?

    init(app: AppState, accessibleSize: Bool) throws {
      let selectedScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      scene = selectedScene
      previousKeyWindow = selectedScene.windows.first(where: \.isKeyWindow)
      let root = NavigationStack {
        Text("Connection menu fixture")
          .toolbar { ToolbarItem(placement: .topBarLeading) { RadioStatusControl() } }
      }
      .environment(\.appState, app)
      .environment(\.dynamicTypeSize, accessibleSize ? .accessibility5 : .large)
      let controller = UIHostingController(rootView: root)
      controller.traitOverrides.preferredContentSizeCategory = accessibleSize
        ? UIContentSizeCategory.accessibilityExtraExtraExtraLarge : UIContentSizeCategory.large
      window = UIWindow(windowScene: scene)
      window.frame = Layout.viewport
      window.rootViewController = controller
      controller.view.frame = window.bounds
      window.makeKeyAndVisible()
      window.layoutIfNeeded()
    }

    var visibleWindows: [UIWindow] {
      scene.windows.filter { !$0.isHidden && $0.alpha > 0 }
    }

    func close() {
      window.rootViewController?.dismiss(animated: false)
      window.rootViewController = nil
      window.isHidden = true
      window.windowScene = nil
      previousKeyWindow?.makeKeyAndVisible()
    }

    func describe() -> String {
      nodes(in: visibleWindows).map { node in
        "[\(node.label) value=\(node.value) traits=\(node.traits.rawValue) type=\(type(of: node.object)) frame=\(node.frame)]"
      }.joined(separator: " ")
    }

    func nodes(in windows: [UIWindow]) -> [AccessNode] {
      var result: [AccessNode] = []
      var seen = Set<ObjectIdentifier>()
      func visit(_ object: NSObject, in owner: UIWindow) {
        guard seen.insert(ObjectIdentifier(object)).inserted else { return }
        if let view = object as? UIView, view.isHidden || view.accessibilityElementsHidden { return }
        let count = object.accessibilityElementCount()
        let label = object.accessibilityLabel ?? ""
        if object.isAccessibilityElement, !label.isEmpty {
          result.append(AccessNode(
            object: object,
            window: owner,
            label: label,
            value: object.accessibilityValue ?? "",
            traits: object.accessibilityTraits,
            frame: object.accessibilityFrame
          ))
        }
        if count != NSNotFound, count > 0 {
          for index in 0..<count {
            if let child = object.accessibilityElement(at: index) as? NSObject, child !== object { visit(child, in: owner) }
          }
        } else if let elements = object.accessibilityElements, !elements.isEmpty {
          for case let child as NSObject in elements where child !== object {
            visit(child, in: owner)
          }
        } else if let view = object as? UIView {
          for child in view.subviews where child.alpha > 0 {
            visit(child, in: owner)
          }
        }
      }
      windows.forEach { visit($0, in: $0) }
      return result
    }
  }

  @MainActor
  private struct AccessNode {
    let object: NSObject
    let window: UIWindow
    let label: String
    let value: String
    let traits: UIAccessibilityTraits
    let frame: CGRect

    var hasWindowContainedAXFrame: Bool {
      !frame.isEmpty && window.convert(window.bounds, to: nil).contains(frame)
    }
  }
}
