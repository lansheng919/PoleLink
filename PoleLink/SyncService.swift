import Foundation
import Network
import SwiftData
import SwiftUI

@MainActor final class SyncService: ObservableObject {
    @Published var online = true
    @Published var syncing = false
    @Published var message = "Ready for fieldwork"
    private let monitor = NWPathMonitor()
    private var context: ModelContext?
    private var timer: Timer?
    @AppStorage("apiURL") var apiURL = "http://localhost:8080"
    func start(_ context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.online = path.status == .satisfied
                if path.status == .satisfied { await self?.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "network"))
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
    }
    func sync() async {
        guard !syncing, online, let context else { return }
        syncing = true
        defer { syncing = false }
        do {
            guard let base = URL(string: apiURL), ["https", "http"].contains(base.scheme ?? ""), base.host != nil else {
                throw NSError(domain: "API", code: 0, userInfo: [NSLocalizedDescriptionKey: "Enter a valid API address in Settings."])
            }
            let records = try context.fetch(FetchDescriptor<LocalSurvey>()).filter { $0.state == "queued" }
            for record in records {
                do {
                    var request = URLRequest(url: base.appendingPathComponent("api/v1/associations"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 20
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(record.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
                    request.httpBody = record.payload
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard (200...299).contains(http.statusCode) else {
                        struct APIError: Decodable { var error: String }
                        let detail = (try? JSONDecoder().decode(APIError.self, from: data).error) ?? "Check the API and retry."
                        throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(detail)"])
                    }
                    struct Receipt: Decodable { var id: UUID; var accepted: Bool }
                    let receipt = try JSONDecoder().decode(Receipt.self, from: data)
                    guard receipt.accepted, receipt.id == record.id else { throw URLError(.cannotParseResponse) }
                    record.state = "synced"
                    record.submittedAt = Date()
                    record.lastError = ""
                    try context.save()
                } catch {
                    record.state = "queued"
                    record.submittedAt = nil
                    record.lastError = error.localizedDescription
                    try context.save()
                    message = "Saved locally. Sync will retry."
                }
            }
            if records.isEmpty { message = "No pending submissions" }
            else if records.allSatisfy({ $0.state == "synced" }) { message = "All submissions synced" }
        } catch { message = error.localizedDescription }
    }
}
