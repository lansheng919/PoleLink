import Foundation
import SwiftData

struct Capture: Codable, Identifiable {
    var id = UUID()
    var value: String
    var originalValue: String
    var confidence: Double
    var verification: String
    var confidenceSource: String
    var capturedAt = Date()
    var photo: Data
    var isDemo: Bool
}

struct Survey: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var pole: Capture?
    var lights: [Capture] = []
    var isDemo = false
}

@Model final class LocalSurvey {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var payload: Data
    var state: String
    var lastError: String
    var submittedAt: Date?
    init(_ survey: Survey) throws {
        id = survey.id
        createdAt = survey.createdAt
        payload = try JSONEncoder.api.encode(survey)
        state = "draft"
        lastError = ""
    }
    var survey: Survey? { try? JSONDecoder.api.decode(Survey.self, from: payload) }
}

extension JSONEncoder {
    static var api: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var api: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

enum CaptureRules {
    static let threshold = 0.90
    // Replace with the utility's production Pole ID and serial formats before rollout.
    static func valid(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$", options: .regularExpression) != nil
    }
    static func serial(_ raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["serialNumber"] as? String { return value }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
