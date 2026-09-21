import SwiftUI
import SwiftData

@main struct PoleLinkApp: App {
    var body: some Scene {
        WindowGroup { HomeView() }
            .modelContainer(for: LocalSurvey.self)
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query(sort: \LocalSurvey.createdAt, order: .reverse) private var records: [LocalSurvey]
    @StateObject private var sync = SyncService()
    @State private var settings = false
    @State private var error: String?
    @State private var selected: LocalSurvey?
    @AppStorage("demoMode") private var demo = true
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Every light.\nConnected.").font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("Capture a pole, link its lights, and submit with confidence.").foregroundStyle(.secondary)
                        HStack {
                            Label(sync.online ? "Online" : "Offline · saved on device", systemImage: sync.online ? "wifi" : "wifi.slash")
                            Spacer()
                            if demo { Text("DEMO").font(.caption.bold()).padding(6).background(.orange.opacity(0.15), in: Capsule()) }
                        }.font(.caption).foregroundStyle(.secondary)
                        Button(action: create) { Label("Start pole survey", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent)
                    }.padding(.vertical, 12)
                }
                Section {
                    HStack {
                        metric("Surveys", records.count)
                        Spacer()
                        metric("Pending", records.filter { $0.state == "queued" }.count)
                        Spacer()
                        metric("Synced", records.filter { $0.state == "synced" }.count)
                    }.padding(.vertical, 8)
                }
                Section("Field activity") {
                    if records.isEmpty { ContentUnavailableView("Ready for your first pole", systemImage: "light.beacon.max", description: Text("Start a survey to capture a pole and its street lights.")) }
                    ForEach(records) { record in
                        NavigationLink { SurveyView(record: record, sync: sync) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(record.survey?.pole?.value ?? "New pole survey").font(.headline)
                                    Spacer()
                                    Text(record.state.capitalized).font(.caption.bold()).foregroundStyle(record.state == "synced" ? .green : .secondary)
                                }
                                Text("\(record.survey?.lights.count ?? 0) lights · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                if record.survey?.isDemo == true { Text("Simulated data").font(.caption2).foregroundStyle(.orange) }
                            }.padding(.vertical, 6)
                        }
                    }
                }
                Section { Button { Task { await sync.sync() } } label: { Label(sync.syncing ? "Synchronising…" : "Sync now", systemImage: "arrow.triangle.2.circlepath") }.disabled(sync.syncing)
                    Text(sync.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PoleLink")
            .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") } }
            .sheet(isPresented: $settings) { SettingsView() }
            .navigationDestination(item: $selected) { SurveyView(record: $0, sync: sync) }
            .task { sync.start(context) }
            .onChange(of: phase) { _, value in if value == .active { Task { await sync.sync() } } }
            .alert("Unable to save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }.tint(Color(red: 0.02, green: 0.48, blue: 0.44))
    }
    private func metric(_ title: String, _ count: Int) -> some View { VStack(alignment: .leading) { Text("\(count)").font(.title.bold()); Text(title).font(.caption).foregroundStyle(.secondary) } }
    private func create() {
        do {
            var survey = Survey(); survey.isDemo = demo
            let record = try LocalSurvey(survey)
            context.insert(record)
            try context.save()
            selected = record
        } catch { context.rollback(); self.error = error.localizedDescription }
    }
}

struct SurveyView: View {
    @Bindable var record: LocalSurvey
    @ObservedObject var sync: SyncService
    @Environment(\.modelContext) private var context
    @State private var scanner: ScanTarget?
    @State private var error: String?
    @State private var photo: Capture?
    private var survey: Survey { record.survey ?? Survey() }
    enum ScanTarget: String, Identifiable { case pole, light; var id: String { rawValue } }
    var body: some View {
        List {
            Section {
                Label(record.state == "draft" ? "Capture & review" : record.state == "queued" ? "Saved locally · awaiting sync" : "Submission received", systemImage: record.state == "synced" ? "checkmark.icloud.fill" : "externaldrive.fill")
                if survey.isDemo { Text("DEMO SURVEY · simulated photos").font(.caption).foregroundStyle(.orange) }
            }
            Section("01  Pole identification") {
                if let pole = survey.pole {
                    captureRow(pole)
                    if record.state == "draft" { Button("Recapture pole label") { scanner = .pole } }
                }
                else { Button("Scan pole label") { scanner = .pole }.disabled(record.state != "draft") }
            }
            Section("02  Associated street lights · \(survey.lights.count)") {
                ForEach(survey.lights) { capture in
                    captureRow(capture).swipeActions {
                        if record.state == "draft" {
                            Button("Remove", role: .destructive) { removeLight(capture.id) }
                        }
                    }
                }
                if record.state == "draft" { Button { scanner = .light } label: { Label("Add street light", systemImage: "plus.circle.fill") }.disabled(survey.pole == nil) }
            }
            Section("Data quality") {
                LabeledContent("High confidence", value: "\(captures.filter { $0.verification == "high" }.count)")
                LabeledContent("Manually verified", value: "\(captures.filter { $0.verification == "manual" }.count)")
                Text("Tap any capture to inspect its photo. Each light is linked to this pole. Submitted surveys are locked to preserve the integration record.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if record.state == "draft" {
                    Button("Confirm & submit survey") {
                        guard record.payload.count <= 40 * 1024 * 1024 else {
                            error = "This survey exceeds the mock API’s 40 MiB limit. Remove lights and capture them in another survey."; return
                        }
                        record.state = "queued"
                        do { try context.save(); Task { await sync.sync() } }
                        catch { context.rollback(); self.error = error.localizedDescription }
                    }.disabled(survey.pole == nil || survey.lights.isEmpty)
                } else if record.state == "queued" {
                    Button("Retry sync") { Task { await sync.sync() } }.disabled(sync.syncing)
                }
                if !record.lastError.isEmpty { Text(record.lastError).font(.caption).foregroundStyle(.orange) }
                if let date = record.submittedAt { Text("Synced \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(survey.pole?.value ?? "New survey")
        .sheet(item: $scanner) { target in
            ScannerView(isPole: target == .pole, demo: survey.isDemo) { capture in
                var updated = survey
                if target == .pole { updated.pole = capture }
                else {
                    guard !updated.lights.contains(where: { $0.value.caseInsensitiveCompare(capture.value) == .orderedSame }) else {
                        throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "This serial number is already linked to this pole."])
                    }
                    updated.lights.append(capture)
                }
                record.payload = try JSONEncoder.api.encode(updated)
                do { try context.save() } catch { context.rollback(); throw error }
            }
        }
        .sheet(item: $photo) { capture in
            NavigationStack {
                VStack(spacing: 20) {
                    if let image = UIImage(data: capture.photo) { Image(uiImage: image).resizable().scaledToFit() }
                    Text(capture.value).font(.title2.monospaced())
                    Text(capture.verification == "high" ? "High confidence" : "Manually verified")
                    Text("Original reading: \(capture.originalValue.isEmpty ? "None" : capture.originalValue)").font(.caption)
                    Text(capture.capturedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                }.padding().navigationTitle("Capture evidence").toolbar { Button("Done") { photo = nil } }
            }
        }
        .alert("Unable to submit", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func removeLight(_ id: UUID) {
        var updated = survey
        updated.lights.removeAll { $0.id == id }
        do { record.payload = try JSONEncoder.api.encode(updated); try context.save() }
        catch { context.rollback(); self.error = error.localizedDescription }
    }
    private var captures: [Capture] { (survey.pole.map { [$0] } ?? []) + survey.lights }
    private func captureRow(_ capture: Capture) -> some View {
        Button { photo = capture } label: {
            HStack(spacing: 14) {
                if let image = UIImage(data: capture.photo) { Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10)) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(capture.value).font(.headline.monospaced()).foregroundStyle(.primary)
                    Label(capture.verification == "high" ? "High confidence" : "Manually verified", systemImage: capture.verification == "high" ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark").font(.caption).foregroundStyle(capture.verification == "high" ? .green : .orange)
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("apiURL") private var apiURL = "http://localhost:8080"
    @AppStorage("demoMode") private var demo = true
    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") { Toggle("Demo mode", isOn: $demo)
                    Text("Applies to new surveys. Demo mode lets you exercise high and low confidence capture without a camera.").font(.caption)
                }
                Section("Integration endpoint") {
                    TextField("API base URL", text: $apiURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("On an iPhone, use your Mac’s LAN IP, for example http://192.168.1.20:8080. Use localhost in the simulator. The mock server must be running.").font(.caption)
                }
                Section("Offline operation") { Text("Drafts and photos are saved on this device. Confirmed surveys queue locally, then retry when the app is open and connectivity returns. iOS may suspend the app in the background; reopening resumes sync.") }
                Section("Recognition policy") { Text("Pole OCR: ≥90% confidence and three consistent readings. QR: three consistent decoded values. IDs must be 3–64 letters, digits, dots, hyphens or underscores. QR accepts a plain serial or JSON with serialNumber.") }
            }.navigationTitle("Settings").toolbar { Button("Done") { dismiss() } }
        }
    }
}
