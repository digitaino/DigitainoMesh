import Foundation

/// Where DigitainoMesh sends people. The app is Avi0n's MeshCore One; this fork is shared on
/// TestFlight with a small group and is never sold, so anyone who wants to support the app
/// is sent to Avi0n, and anyone with a problem in the fork is kept away from Avi0n's tracker.
enum ForkCredit {
  /// Avi0n's GitHub Sponsors page (upstream's `.github/FUNDING.yml`).
  static let sponsorsURL = URL(string: "https://github.com/sponsors/Avi0n")!
  static let upstreamRepositoryURL = URL(string: "https://github.com/Avi0n/MeshCoreOne")!
  static let forkRepositoryURL = URL(string: "https://github.com/digitaino/DigitainoMesh")!
  static let forkIssuesURL = URL(string: "https://github.com/digitaino/DigitainoMesh/issues")!
  static let forkEmail = "mesh@digitaino.com"
  static let forkMailtoURL = URL(string: "mailto:\(forkEmail)")!
}
