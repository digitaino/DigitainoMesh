import SwiftUI

/// Bottom controls for the route planner: drawing controls, route review, and navigation guidance.
struct RoutePlannerControls: View {
    @Bindable var viewModel: SignalSurveyViewModel

    var body: some View {
        switch viewModel.routePlannerMode {
        case .inactive, .waitingForWeb:
            EmptyView()

        case .drawingPolygon:
            drawingControls

        case .reviewingRoute:
            reviewControls

        case .navigating:
            navigationControls
        }
    }

    // MARK: - Drawing Controls

    private var drawingControls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.undoPolygonVertex()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.drawingPolygonPoints.isEmpty)

            Button {
                viewModel.drawingPolygonPoints = []
            } label: {
                Label("Clear", systemImage: "xmark")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.drawingPolygonPoints.isEmpty)

            Button {
                viewModel.generateRoute()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.drawingPolygonPoints.count < 3)

            Button {
                viewModel.cancelRoutePlanning()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Review Controls

    private var reviewControls: some View {
        VStack(spacing: 8) {
            if let route = viewModel.currentRoute {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(route.waypoints.count) cells in route")
                            .font(.subheadline.weight(.semibold))
                        if route.excludedSurveyedCells {
                            Text("Surveyed cells excluded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Toggle("Exclude surveyed", isOn: $viewModel.excludeSurveyedCells)
                    .font(.caption)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: viewModel.excludeSurveyedCells) { _, _ in
                        viewModel.generateRoute()
                    }
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.routePlannerMode = .drawingPolygon
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.startNavigation()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.currentRoute?.waypoints.isEmpty ?? true)

                Button {
                    viewModel.cancelRoutePlanning()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Navigation Controls

    private var navigationControls: some View {
        VStack(spacing: 8) {
            if let route = viewModel.currentRoute {
                // Direction arrow and distance
                RouteGuidanceOverlay(route: route, userHeading: viewModel.userHeading, userLocation: viewModel.userLocation)

                // Progress bar
                HStack {
                    Text("Cell \(route.completedCount + 1) of \(route.waypoints.count)")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Text("\(route.completedCount) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: Double(route.completedCount), total: Double(route.waypoints.count))
                    .tint(.green)
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.skipCurrentWaypoint()
                } label: {
                    Label("Skip", systemImage: "forward.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.stopNavigation()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}
