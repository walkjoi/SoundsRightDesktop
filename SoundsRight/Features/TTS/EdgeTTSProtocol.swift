import Foundation
import CryptoKit

enum EdgeTTSProtocol {
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMsGecVersion = "1-143.0.3650.75"
    private static let windowsFileTimeEpoch: TimeInterval = -11644473600

    static func generateSecMsGec() -> String {
        let now = Date()
        let timeIntervalSince1601 = (now.timeIntervalSince1970 - windowsFileTimeEpoch) * 10_000_000
        let roundedTicks = Int64(timeIntervalSince1601 / 3_000_000_000) * 3_000_000_000

        let ticksString = String(format: "%lld", roundedTicks)
        let concatenated = ticksString + trustedClientToken

        let data = concatenated.data(using: .utf8)!
        let digest = SHA256.hash(data: data)
        let hashBytes = Data(digest)

        return hashBytes.map { String(format: "%02X", $0) }.joined()
    }

    static func buildSSML(text: String, voice: String, rate: String) -> String {
        let escapedText = escapeXML(text)
        return """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="en-US">
          <voice name="\(voice)">
            <prosody rate="\(rate)">\(escapedText)</prosody>
          </voice>
        </speak>
        """
    }

    static func buildConfigMessage() -> String {
        let timestamp = jsTimestamp()
        let config = #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
        return "X-Timestamp:\(timestamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n\(config)"
    }

    static func buildSynthesisMessage(ssml: String) -> String {
        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let timestamp = jsTimestamp()
        return "X-RequestId:\(requestId)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp)\r\nPath:ssml\r\n\r\n\(ssml)"
    }

    /// Returns a JavaScript-style ISO 8601 timestamp (e.g. "2025-04-10T12:00:00.000Z")
    private static func jsTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func buildWebSocketURL(token: String) -> URL {
        let connectionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var components = URLComponents(string: AppConstants.edgeTTSEndpoint)!

        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: token),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: secMsGecVersion),
            URLQueryItem(name: "ConnectionId", value: connectionId)
        ]

        return components.url!
    }

    private static func escapeXML(_ text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
        return escaped
    }
}
