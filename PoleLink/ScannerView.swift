import SwiftUI

struct ScannerView: View {
    let isPole: Bool
    let demo: Bool
    let onSave: (Capture) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = Camera()
    @State private var detected = ""
    @State private var edited = ""
    @State private var score = 0.0
    @State private var verifying = false
    @State private var busy = false
    @State private var high = false
    @State private var failure: String?
    @State private var pending: Capture?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text(isPole ? "Find the pole label" : "Scan the light’s QR code")
                        .font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                    Text(isPole ? "Keep one ID inside the guide. Hold steady for automatic capture." : "Keep one QR code in view. Three matching reads confirm the serial number.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    ZStack {
                        if demo {
                            Color(red: 0.08, green: 0.17, blue: 0.22)
                            VStack(spacing: 18) {
                                Image(systemName: isPole ? "text.viewfinder" : "qrcode.viewfinder").font(.system(size: 68))
                                Text("DEMO CAMERA").font(.caption.monospaced()).tracking(3)
                            }.foregroundStyle(.white)
                        } else { CameraPreview(camera: camera) }
                        RoundedRectangle(cornerRadius: 14).stroke(high ? .green : .white.opacity(0.8), lineWidth: 3).padding(.horizontal, 26).padding(.vertical, 70)
                    }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 24))
                    VStack(alignment: .leading, spacing: 12) {
                        Label(high ? "High confidence" : detected.isEmpty ? "Searching" : "Verification needed", systemImage: high ? "checkmark.seal.fill" : "viewfinder")
                            .foregroundStyle(high ? .green : .orange)
                        Text(detected.isEmpty ? "Waiting for a reading…" : detected).font(.title2.monospaced().bold()).foregroundStyle(high ? .green : .primary)
                        ProgressView(value: score).tint(high ? .green : .orange)
                        Text(isPole ? "OCR confidence: \(Int(score * 100))% · threshold 90%" : "Read consistency: \(Int(score * 100))% · 3 matching frames required")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding().background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                    if verifying {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Verify before taking the photo").font(.headline)
                            TextField(isPole ? "Pole ID" : "Serial number", text: $edited).textFieldStyle(.roundedBorder).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            Text("Check the physical label, correct the value, then keep it in view while capturing.").font(.caption).foregroundStyle(.secondary)
                            Button("Confirm & capture photo") { takePhoto(manual: true) }.buttonStyle(.borderedProminent).disabled(!CaptureRules.valid(edited) || busy)
                            Button("Resume scanning") { verifying = false }.disabled(busy)
                        }
                    } else {
                        Button("Verify or enter manually") { edited = detected; verifying = true }.buttonStyle(.bordered).disabled(busy)
                    }
                    if demo {
                        HStack {
                            Button("High confidence") { simulate(high: true) }
                            Button("Low confidence") { simulate(high: false) }
                        }.buttonStyle(.bordered).disabled(busy || verifying)
                        Text("Demo photos and records are marked as simulated.").font(.caption).foregroundStyle(.secondary)
                    }
                    if busy { ProgressView("Capturing and saving…") }
                }.padding(24)
            }
            .navigationTitle(isPole ? "Capture pole" : "Add street light")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .onAppear {
                camera.isPole = isPole
                camera.onDetection = { value, confidence, ready, stable in
                    guard !verifying, !busy else { return }
                    detected = value; score = confidence; high = ready
                    if ready { takePhoto(manual: false) }
                    else if stable { edited = value; verifying = true }
                }
                camera.onPhoto = { data in finish(data) }
                camera.onError = { error in busy = false; pending = nil; failure = error }
                if !demo { camera.start() }
            }
            .onDisappear { camera.stop() }
            .alert("Capture needs attention", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
    private func simulate(high: Bool) {
        detected = isPole ? "PL-10482" : "SL-\(Int.random(in: 100000...999999))"
        score = high ? 0.98 : 0.64
        self.high = high
        if high { takePhoto(manual: false) }
        else { edited = detected; verifying = true }
    }
    private func takePhoto(manual: Bool) {
        guard !busy else { return }
        let value = (manual ? edited : detected).trimmingCharacters(in: .whitespacesAndNewlines)
        guard CaptureRules.valid(value) else { return }
        busy = true
        pending = Capture(value: value, originalValue: detected, confidence: score,
                          verification: manual ? "manual" : "high", confidenceSource: demo ? "demo" : isPole ? "visionOCR" : "qrReadConsistency",
                          photo: Data(), isDemo: demo)
        if demo {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
            let image = renderer.image { context in
                UIColor(red: 0.08, green: 0.17, blue: 0.22, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
                ("SIMULATED PHOTO\n\n\(value)" as NSString).draw(in: CGRect(x: 60, y: 170, width: 800, height: 350), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 46, weight: .bold), .foregroundColor: UIColor.white])
            }
            finish(image.jpegData(compressionQuality: 0.8)!)
        } else { camera.capture() }
    }
    private func finish(_ data: Data) {
        guard var capture = pending else { return }
        if let image = UIImage(data: data) {
            let ratio = min(1, 1600 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            capture.photo = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }.jpegData(compressionQuality: 0.8) ?? data
        } else { capture.photo = data }
        do { try onSave(capture); dismiss() }
        catch { busy = false; pending = nil; failure = error.localizedDescription; verifying = true; edited = capture.value }
    }
}
