import SwiftUI

struct ToolsView: View {
    private static let lineOfSightSidebarWidthMin: CGFloat = 380
    private static let lineOfSightSidebarWidthIdeal: CGFloat = 440
    private static let lineOfSightSidebarWidthMax: CGFloat = 560

    private enum ToolSelection: Hashable, CaseIterable {
        case weather
        case tracePath
        case repeaterBenchmark
        case lineOfSight
        case rxLog
        case noiseFloor
        case nodeDiscovery
        case trafficMap
        case signalSurvey
        case pathMapGenerator
        case cli

        var title: String {
            switch self {
            case .weather: "Weather"
            case .tracePath: L10n.Tools.Tools.tracePath
            case .repeaterBenchmark: "Repeater Benchmark"
            case .lineOfSight: L10n.Tools.Tools.lineOfSight
            case .rxLog: L10n.Tools.Tools.rxLog
            case .noiseFloor: L10n.Tools.Tools.noiseFloor
            case .nodeDiscovery: L10n.Tools.Tools.nodeDiscovery
            case .trafficMap: L10n.Tools.Tools.trafficMap
            case .signalSurvey: "Signal Survey"
            case .pathMapGenerator: "Path Map"
            case .cli: L10n.Tools.Tools.cli
            }
        }

        var systemImage: String {
            switch self {
            case .weather: "cloud.bolt.fill"
            case .tracePath: "point.3.connected.trianglepath.dotted"
            case .repeaterBenchmark: "gauge.with.dots.needle.33percent"
            case .lineOfSight: "eye"
            case .rxLog: "waveform.badge.magnifyingglass"
            case .noiseFloor: "waveform"
            case .nodeDiscovery: "dot.radiowaves.left.and.right"
            case .trafficMap: "map.circle"
            case .signalSurvey: "antenna.radiowaves.left.and.right"
            case .pathMapGenerator: "point.3.connected.trianglepath.dotted"
            case .cli: "terminal"
            }
        }

        var requiresRadio: Bool {
            self != .lineOfSight && self != .trafficMap && self != .signalSurvey && self != .pathMapGenerator && self != .repeaterBenchmark && self != .weather
        }
    }

    private enum SidebarDestination: Hashable {
        case lineOfSightPoints
    }

    @Environment(\.appState) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedTool: ToolSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarPath = NavigationPath()
    @State private var isShowingLineOfSightPoints = false
    @State private var navigateToSurvey = false

    @State private var lineOfSightViewModel = LineOfSightViewModel()
    @State private var benchmarkViewModel = BenchmarkViewModel()

    private var shouldUseSplitView: Bool {
        horizontalSizeClass == .regular
    }

    private var visibleTools: [ToolSelection] {
        ToolSelection.allCases
    }

    var body: some View {
        Group {
        if shouldUseSplitView {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                if isShowingLineOfSightPoints {
                    sidebarStack
                        .navigationSplitViewColumnWidth(
                            min: Self.lineOfSightSidebarWidthMin,
                            ideal: Self.lineOfSightSidebarWidthIdeal,
                            max: Self.lineOfSightSidebarWidthMax
                        )
                } else {
                    sidebarStack
                }
            } detail: {
                NavigationStack {
                    if selectedTool == .lineOfSight {
                        toolDetailView
                            .navigationBarTitleDisplayMode(.inline)
                    } else {
                        toolDetailView
                            .navigationTitle(selectedTool?.title ?? L10n.Tools.Tools.title)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .liquidGlassToolbarBackground()
            }
            .ignoresSafeArea(edges: .top)
            .onChange(of: sidebarPath) { _, _ in
                if sidebarPath.isEmpty, isShowingLineOfSightPoints {
                    isShowingLineOfSightPoints = false
                    selectedTool = nil
                }
            }
            .onChange(of: appState.connectedDevice) { _, newDevice in
                if newDevice == nil, selectedTool?.requiresRadio == true {
                    selectedTool = nil
                    isShowingLineOfSightPoints = false
                    sidebarPath = NavigationPath()
                }
            }
        } else {
            NavigationStack {
                List {
                    ForEach(visibleTools, id: \.self) { tool in
                        NavigationLink {
                            toolDestination(for: tool)
                        } label: {
                            toolLabel(for: tool)
                        }
                    }
                }
                .navigationTitle(L10n.Tools.Tools.title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        BLEStatusIndicatorView()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        SignalBarsToolbarItem()
                    }
                }
                .navigationDestination(isPresented: $navigateToSurvey) {
                    SignalSurveyView()
                }
            }
        }
        } // Group
        .onChange(of: appState.navigation.pendingSurveyNavigation) { _, pending in
            guard pending else { return }
            if shouldUseSplitView {
                selectTool(.signalSurvey)
            } else {
                navigateToSurvey = true
            }
            appState.navigation.clearPendingSurveyNavigation()
        }
    }

    private var sidebarStack: some View {
        NavigationStack(path: $sidebarPath) {
            List {
                ForEach(visibleTools, id: \.self) { tool in
                    Button {
                        selectTool(tool)
                    } label: {
                        toolLabel(for: tool)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(L10n.Tools.Tools.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BLEStatusIndicatorView()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SignalBarsToolbarItem()
                }
            }
            .navigationDestination(for: SidebarDestination.self) { destination in
                switch destination {
                case .lineOfSightPoints:
                    LineOfSightView(viewModel: lineOfSightViewModel, layoutMode: .panel)
                        .navigationTitle(L10n.Tools.Tools.lineOfSight)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private func selectTool(_ tool: ToolSelection) {
        selectedTool = tool
        sidebarPath = NavigationPath()

        if tool == .lineOfSight {
            isShowingLineOfSightPoints = true
            sidebarPath.append(SidebarDestination.lineOfSightPoints)
        } else {
            isShowingLineOfSightPoints = false
        }
    }

    @ViewBuilder
    private func toolLabel(for tool: ToolSelection) -> some View {
        if tool == .signalSurvey && appState.isSurveyActive {
            HStack {
                Label(tool.title, systemImage: tool.systemImage)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        } else {
            Label(tool.title, systemImage: tool.systemImage)
        }
    }

    @ViewBuilder
    private func toolDestination(for tool: ToolSelection) -> some View {
        switch tool {
        case .weather: WeatherView()
        case .tracePath: TracePathView()
        case .repeaterBenchmark: BenchmarkView(viewModel: benchmarkViewModel)
        case .lineOfSight: LineOfSightView()
        case .rxLog: RxLogView()
        case .noiseFloor: NoiseFloorView()
        case .nodeDiscovery: NodeDiscoveryView()
        case .trafficMap: TrafficHeatmapView()
        case .signalSurvey: SignalSurveyView()
        case .pathMapGenerator: PathMapGeneratorView()
        case .cli: CLIToolView()
        }
    }

    @ViewBuilder
    private var toolDetailView: some View {
        switch selectedTool {
        case .weather: WeatherView()
        case .tracePath: TracePathView()
        case .repeaterBenchmark: BenchmarkView(viewModel: benchmarkViewModel)
        case .lineOfSight: LineOfSightView(viewModel: lineOfSightViewModel, layoutMode: .map)
        case .rxLog: RxLogView()
        case .noiseFloor: NoiseFloorView()
        case .nodeDiscovery: NodeDiscoveryView()
        case .trafficMap: TrafficHeatmapView()
        case .signalSurvey: SignalSurveyView()
        case .pathMapGenerator: PathMapGeneratorView()
        case .cli: CLIToolView()
        case .none: ContentUnavailableView(L10n.Tools.Tools.selectTool, systemImage: "wrench.and.screwdriver")
        }
    }
}

#Preview {
    ToolsView()
        .environment(\.appState, AppState())
}
