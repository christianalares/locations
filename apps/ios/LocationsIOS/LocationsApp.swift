import LocationsKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
private final class LocationsAppModel {
    let syncSession: BlipCloudSession
    let timeline: BlipTimelineStore

    init() {
        let session = BlipCloudSession()
        syncSession = session
        timeline = BlipTimelineStore(syncSession: session)
    }

    func consumeSyncBootstrapIfPresent() throws {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        let file = documents.appendingPathComponent("locations-sync-bootstrap.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }

        struct Bootstrap: Decodable {
            let serverURL: String
            let deviceToken: String
        }
        let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: Data(contentsOf: file))
        guard let url = URL(string: bootstrap.serverURL) else {
            throw LocationsSyncError.invalidServer
        }
        try syncSession.configure(baseURL: url, token: bootstrap.deviceToken)
        try FileManager.default.removeItem(at: file)
    }
}

@MainActor
private final class LocationsAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BlipTimelineAutomaticCaptureBootstrap.restoreAfterLaunch()
        BlipFont.configureIOSNavigationTypography()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BlipTimelineAutomaticCaptureBootstrap.prepareForegroundCapture()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BlipCloudSession.handleBackgroundSyncEvents(identifier: identifier, completion: completionHandler)
    }
}

@main
struct LocationsApp: App {
    @UIApplicationDelegateAdaptor(LocationsAppDelegate.self) private var appDelegate
    @State private var model: LocationsAppModel

    init() {
        // SwiftUI constructs the App before UIKit calls didFinishLaunching.
        // Restore Core Location before loading and preparing the full ledger
        // so background relaunches keep Blip's early restoration behavior.
        BlipTimelineAutomaticCaptureBootstrap.restoreAfterLaunch()
        _model = State(initialValue: LocationsAppModel())
    }

    var body: some Scene {
        WindowGroup {
            LocationsRootView(model: model)
        }
    }
}

private struct LocationsRootView: View {
    let model: LocationsAppModel
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var mapScope
    @StateObject private var locationPermissions = LocationsLocationPermissions()
    @State private var showsTimeline = true
    @State private var showsTimelineControls = false
    @State private var showsImport = false
    @State private var showsSettings = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .top) {
            if model.timeline.hasCapturedData {
                BlipTimelineView(
                    store: model.timeline,
                    isPresented: $showsTimeline,
                    showsTimelineControls: $showsTimelineControls,
                    showsAppSettings: $showsSettings,
                    appSettings: {
                        AnyView(LocationsSettingsView(
                            session: model.syncSession,
                            timeline: model.timeline,
                            permissions: locationPermissions
                        ))
                    },
                    showsTrackingWarning: false,
                    mapScope: mapScope
                )
                if model.timeline.trackingState != .active || !locationPermissions.isReady {
                    trackingStatusCard
                        .padding(.horizontal, 24)
                        .padding(.top, 116)
                }
            } else {
                ContentUnavailableView {
                    Label("Locations", systemImage: "location.circle")
                } description: {
                    Text("Connect to your Locations service to restore your history, or import a Blip ledger before starting capture.")
                } actions: {
                    Button("Connect and restore") { showsSettings = true }
                        .buttonStyle(.borderedProminent)
                    Button("Import Blip ledger") { showsImport = true }
                        .buttonStyle(.borderedProminent)
                }
                .sheet(isPresented: $showsSettings) {
                    LocationsSettingsView(
                        session: model.syncSession,
                        timeline: model.timeline,
                        permissions: locationPermissions
                    )
                }
            }

            HStack {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Settings")

                Spacer()

                if model.timeline.hasCapturedData {
                    MapCompass(scope: mapScope)
                    MapUserLocationButton(scope: mapScope)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mapScope(mapScope)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .fileImporter(
            isPresented: $showsImport,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            do {
                let urls = try result.get()
                let ledger = urls.first {
                    $0.lastPathComponent.lowercased().hasPrefix("timeline-v1")
                }
                guard let ledger else {
                    errorMessage = "Choose timeline-v1.json from the Blip export."
                    return
                }
                let pending = urls.first { $0.lastPathComponent.contains("pending-capture") }
                let granted = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { granted.forEach { $0.stopAccessingSecurityScopedResource() } }

                try model.timeline.importLegacyLedger(from: ledger, pendingCaptureURL: pending)
                showsTimeline = true
                locationPermissions.promptOnLaunchIfNeeded()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Locations", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            if model.timeline.hasCapturedData,
               !ProcessInfo.processInfo.arguments.contains("-blipDemoTimeline") {
                locationPermissions.promptOnLaunchIfNeeded()
            }
            do {
                try model.consumeSyncBootstrapIfPresent()
            } catch {
                errorMessage = error.localizedDescription
            }
            await model.timeline.resumeTrackingAndSync()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                locationPermissions.refresh()
                Task { await model.timeline.resumeTrackingAndSync() }
            } else if phase == .background {
                model.timeline.flushPendingCloudBackup()
            }
        }
    }

    private var trackingStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.timeline.trackingEnabled
                    ? "location.triangle.fill"
                    : "location.slash.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.28, green: 0.83, blue: 0.70))
                    .frame(width: 38, height: 38)
                    .background(Color(red: 0.12, green: 0.35, blue: 0.34), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.timeline.trackingEnabled
                        ? (locationPermissions.attentionTitle ?? model.timeline.trackingState.title)
                        : "Tracking is off")
                        .font(.headline)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(locationPermissions.isReady ? "Open settings" : locationPermissions.actionTitle) {
                if locationPermissions.isReady {
                    showsSettings = true
                } else {
                    locationPermissions.requestNeededAccess()
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.10, green: 0.54, blue: 0.46))
        }
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var statusMessage: String {
        if locationPermissions.attentionTitle != nil {
            return locationPermissions.attentionMessage
        }
        if !model.timeline.trackingEnabled {
            return "Your history is safe. New visits and journeys are paused."
        }
        return "Check the tracking status in Settings."
    }
}

private struct LocationsSettingsView: View {
    let session: BlipCloudSession
    let timeline: BlipTimelineStore
    @ObservedObject var permissions: LocationsLocationPermissions
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = ""
    @State private var deviceToken = ""
    @State private var showsConnectionDetails = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(Color(red: 0.23, green: 0.79, blue: 0.66))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Your timeline")
                                .font(.title2.weight(.bold))
                            Text("Capture and sync on this iPhone")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 2)

                    sectionHeading("LOCATION")
                    card {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Timeline tracking")
                                        .font(.headline)
                                    Text(timeline.trackingEnabled
                                        ? "Recording visits and journeys"
                                        : "New visits and journeys are paused")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: timeline.trackingEnabled
                                    ? "location.fill"
                                    : "location.slash")
                                    .foregroundStyle(timeline.trackingEnabled
                                        ? Color(red: 0.16, green: 0.70, blue: 0.57)
                                        : .secondary)
                            }
                            Toggle("Track visits and journeys", isOn: Binding(
                                get: { timeline.trackingEnabled },
                                set: { enabled in
                                    if enabled {
                                        timeline.enableTracking()
                                    } else {
                                        timeline.disableTracking()
                                    }
                                    permissions.refresh()
                                }
                            ))
                            .tint(Color(red: 0.10, green: 0.54, blue: 0.46))
                            Divider()
                            Label(permissions.summary, systemImage: permissions.isReady
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(permissions.isReady
                                    ? Color(red: 0.16, green: 0.70, blue: 0.57)
                                    : .orange)
                            if permissions.attentionTitle != nil {
                                Text(permissions.attentionMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button(permissions.actionTitle) {
                                    permissions.requestNeededAccess()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color(red: 0.10, green: 0.54, blue: 0.46))
                            } else if timeline.trackingEnabled {
                                Text(timeline.backgroundCaptureStatus.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    sectionHeading("CLOUD SYNC")
                    card {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Label("Your history", systemImage: "icloud")
                                    .font(.headline)
                                Spacer()
                                Text(session.isConnected ? "Connected" : "Not connected")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(session.isConnected
                                        ? Color(red: 0.16, green: 0.70, blue: 0.57)
                                        : .secondary)
                            }
                            Text(session.isConnected
                                ? "Recorded changes upload automatically. Your history, saved places, and recording state are backed up."
                                : "Connect to back up this iPhone or restore your history on a new phone.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Divider()
                            if !session.isConnected {
                                Button("Connect and restore") { showsConnectionDetails = true }
                                    .buttonStyle(.bordered)
                            }
                            HStack {
                                Text("Last sync")
                                Spacer()
                                Text(timeline.lastSyncAt?.formatted(date: .abbreviated, time: .shortened)
                                    ?? "Not yet")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            HStack {
                                Text("Changes to sync")
                                Spacer()
                                Text(String(timeline.pendingSyncCount))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            if let syncError = timeline.syncError {
                                Text(syncError)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Button(timeline.isSyncing ? "Syncing…" : "Sync now") {
                                Task { await timeline.synchronizeWithCloud() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!session.isConnected || timeline.isSyncing)
                        }
                    }

                    sectionHeading("ADVANCED")
                    card {
                        DisclosureGroup(isExpanded: $showsConnectionDetails) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("These details are already saved when cloud sync is connected.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Server address", text: $serverURL)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)
                                SecureField("New device token", text: $deviceToken)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)
                                Text("The token is kept in your iPhone’s Keychain. This field stays blank after it is saved.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Save connection and sync") { saveConnection() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(serverURL.isEmpty || deviceToken.isEmpty)
                                if session.isConnected {
                                    Button("Disconnect this iPhone", role: .destructive) {
                                        session.disconnect()
                                    }
                                    .font(.subheadline)
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            Label("Connection details", systemImage: "network")
                                .font(.headline)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            serverURL = session.baseURL?.absoluteString ?? ""
            showsConnectionDetails = !session.isConnected
            permissions.refresh()
        }
        .alert("Sync settings", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 22)
            )
    }

    private func saveConnection() {
        do {
            guard let url = URL(string: serverURL) else {
                throw LocationsSyncError.invalidServer
            }
            try session.configure(baseURL: url, token: deviceToken)
            deviceToken = ""
            Task { await timeline.synchronizeWithCloud() }
            showsConnectionDetails = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
