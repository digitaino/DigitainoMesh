import SwiftUI

/// Bottom controls for the route planner: drawing controls, route review, and navigation guidance.
struct RoutePlannerControls: View {
    @Bindable var viewModel: SignalSurveyViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Summary card (shown transiently after stop/cancel/complete)
            if let summary = viewModel.routeCompletionSummary {
                routeSummaryCard(summary)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                            withAnimation { viewModel.dismissRouteSummary() }
                        }
                    }
            }

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
        .animation(.easeInOut(duration: 0.3), value: viewModel.routeCompletionSummary != nil)
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
                    // Upload button — opt-in server sync
                    Button {
                        viewModel.uploadRouteToServer()
                    } label: {
                        Image(systemName: viewModel.serverRouteID != nil ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                            .font(.title3)
                            .foregroundStyle(viewModel.serverRouteID != nil ? .green : .accentColor)
                    }
                    .disabled(viewModel.serverRouteID != nil)
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

    // MARK: - Route Completion Summary

    private func routeSummaryCard(_ summary: SignalSurveyViewModel.RouteCompletionSummary) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: summary.wasCompleted ? "checkmark.circle.fill" : "stop.circle.fill")
                    .foregroundStyle(summary.wasCompleted ? .green : .orange)
                    .font(.title3)
                Text(summary.wasCompleted ? "Route Complete" : "Route Stopped")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    withAnimation { viewModel.dismissRouteSummary() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                summaryStatColumn(value: summary.completedCount, label: "Done", color: .green)
                summaryStatColumn(value: summary.skippedCount, label: "Skipped", color: .orange)
                summaryStatColumn(value: summary.remainingCount, label: "Remaining", color: .secondary)
            }

            if let duration = summary.duration, duration > 0 {
                Text(formatDuration(duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func summaryStatColumn(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}
