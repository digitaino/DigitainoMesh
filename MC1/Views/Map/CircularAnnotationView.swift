import MapKit
import SwiftUI
import UIKit

/// Shared base for map annotation views that render a colored circle with a downward
/// pointer triangle, an optional floating name label, and a SwiftUI callout.
///
/// Subclasses supply the circle's center content (an icon image, a hex label, …) via
/// `setCenterContent(_:)`, its per-state size via `centerContentSize(selected:)`, the
/// floating label text via `nameLabelText()`, and build the callout in
/// `configureCalloutForSelection()` (calling `installCallout(_:)`). The circle/triangle
/// geometry, selection border, frame/offset math, callout-controller retention, and
/// name-label chrome are centralized here.
class CircularAnnotationView: MKAnnotationView {
    // MARK: - Shared UI

    let circleView = UIView()
    let triangleImageView = UIImageView()

    private var centerContentView: UIView?
    private var nameLabel: UILabel?
    private var nameLabelContainer: UIView?
    private var nameLabelShadow: UIView?
    private var calloutHostingController: UIViewController?

    /// When true, shows a floating name label above the pin while unselected.
    var showsNameLabel: Bool = false {
        didSet { updateNameLabel() }
    }

    // MARK: - Initialization

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupBaseViews()
        canShowCallout = true
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupBaseViews() {
        // Configure circle
        circleView.translatesAutoresizingMaskIntoConstraints = false
        circleView.layer.shadowColor = UIColor.black.cgColor
        circleView.layer.shadowOpacity = 0.3
        circleView.layer.shadowRadius = 2
        circleView.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(circleView)

        // Configure triangle pointer
        triangleImageView.translatesAutoresizingMaskIntoConstraints = false
        triangleImageView.contentMode = .scaleAspectFit
        triangleImageView.image = UIImage(systemName: "triangle.fill")
        triangleImageView.transform = CGAffineTransform(rotationAngle: .pi)
        addSubview(triangleImageView)
    }

    /// Installs the subclass's center content (e.g. an icon image view or hex label),
    /// centered within the circle. Call once from the subclass initializer, then call
    /// `updateLayout(selected:)`.
    func setCenterContent(_ view: UIView) {
        centerContentView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        circleView.addSubview(view)
        centerContentView = view
    }

    // MARK: - Subclass hooks

    /// Size of the center content for the given selection state. Default matches an icon glyph.
    func centerContentSize(selected: Bool) -> CGSize {
        let size: CGFloat = selected ? 20 : 16
        return CGSize(width: size, height: size)
    }

    /// Text for the floating name label, or nil to hide it.
    func nameLabelText() -> String? { nil }

    /// Override to build and install the callout (via `installCallout(_:)`) when selected.
    func configureCalloutForSelection() {}

    /// Hosts a SwiftUI callout as the detail accessory view, retaining its hosting
    /// controller so the content stays live for the duration of the selection.
    func installCallout(_ content: some View) {
        let hosting = UIHostingController(rootView: content)
        hosting.view.backgroundColor = .clear

        // Size the hosting view — MKMapView uses intrinsic content size for callout layout
        let size = hosting.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        hosting.view.frame = CGRect(origin: .zero, size: size)

        detailCalloutAccessoryView = hosting.view
        calloutHostingController = hosting
    }

    // MARK: - Selection

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseInOut) {
                self.updateLayout(selected: selected)
            }
        } else {
            updateLayout(selected: selected)
        }

        // Name label visibility depends on isSelected state
        updateNameLabel()

        if selected {
            configureCalloutForSelection()
        }
    }

    // MARK: - Layout

    func updateLayout(selected: Bool) {
        let circleSize: CGFloat = selected ? 44 : 36
        let triangleSize: CGFloat = 10
        let contentSize = centerContentSize(selected: selected)

        // Remove existing size constraints (centerX/centerY-to-ancestor are stable)
        circleView.constraints.forEach { circleView.removeConstraint($0) }
        centerContentView?.constraints.forEach { centerContentView?.removeConstraint($0) }
        triangleImageView.constraints.forEach { triangleImageView.removeConstraint($0) }

        // Circle constraints
        NSLayoutConstraint.activate([
            circleView.widthAnchor.constraint(equalToConstant: circleSize),
            circleView.heightAnchor.constraint(equalToConstant: circleSize),
            circleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            circleView.topAnchor.constraint(equalTo: topAnchor)
        ])

        // Center content constraints
        if let centerContentView {
            NSLayoutConstraint.activate([
                centerContentView.widthAnchor.constraint(equalToConstant: contentSize.width),
                centerContentView.heightAnchor.constraint(equalToConstant: contentSize.height),
                centerContentView.centerXAnchor.constraint(equalTo: circleView.centerXAnchor),
                centerContentView.centerYAnchor.constraint(equalTo: circleView.centerYAnchor)
            ])
        }

        // Triangle constraints
        NSLayoutConstraint.activate([
            triangleImageView.widthAnchor.constraint(equalToConstant: triangleSize),
            triangleImageView.heightAnchor.constraint(equalToConstant: triangleSize),
            triangleImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            triangleImageView.topAnchor.constraint(equalTo: circleView.bottomAnchor, constant: -3)
        ])

        // Update circle corner radius
        circleView.layer.cornerRadius = circleSize / 2

        // Update border for selected state
        if selected {
            circleView.layer.borderWidth = 3
            circleView.layer.borderColor = UIColor.white.cgColor
        } else {
            circleView.layer.borderWidth = 0
        }

        // Update frame
        let totalHeight = circleSize + triangleSize - 3
        frame = CGRect(x: 0, y: 0, width: circleSize, height: totalHeight)
        centerOffset = CGPoint(x: 0, y: -totalHeight / 2)
    }

    // MARK: - Name Label

    func updateNameLabel() {
        guard showsNameLabel, !isSelected, let text = nameLabelText() else {
            nameLabelContainer?.isHidden = true
            nameLabelShadow?.isHidden = true
            return
        }

        ensureNameLabel()
        nameLabel?.text = text
        nameLabelContainer?.isHidden = false
        nameLabelShadow?.isHidden = false
    }

    private func ensureNameLabel() {
        guard nameLabel == nil else { return }

        // Blur background matching app's material style
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 8
        blur.layer.masksToBounds = true
        addSubview(blur)

        // Shadow container (separate from blur since blur clips)
        let shadow = UIView()
        shadow.translatesAutoresizingMaskIntoConstraints = false
        shadow.backgroundColor = .clear
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.3
        shadow.layer.shadowRadius = 3
        shadow.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        insertSubview(shadow, belowSubview: blur)
        nameLabelContainer = blur
        nameLabelShadow = shadow

        // Label with Dynamic Type support
        let label = UILabel()
        let baseFont = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium)
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: baseFont)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(label)
        nameLabel = label

        NSLayoutConstraint.activate([
            blur.centerXAnchor.constraint(equalTo: centerXAnchor),
            blur.bottomAnchor.constraint(equalTo: topAnchor, constant: -4),
            shadow.topAnchor.constraint(equalTo: blur.topAnchor),
            shadow.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            shadow.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            shadow.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            label.topAnchor.constraint(equalTo: blur.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -8)
        ])
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        calloutHostingController = nil
        detailCalloutAccessoryView = nil
        nameLabelContainer?.isHidden = true
        nameLabelShadow?.isHidden = true
    }
}
