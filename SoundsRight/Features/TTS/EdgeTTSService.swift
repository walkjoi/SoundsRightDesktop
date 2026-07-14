import Foundation
import os

actor EdgeTTSService {
    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "EdgeTTSService")

    // One session for the actor's lifetime: avoids leaking un-invalidated sessions
    // per call and reuses the TLS/WebSocket connection to the Edge endpoint.
    private let session: URLSession

    init() {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = AppConstants.edgeTTSIdleTimeout
        sessionConfig.timeoutIntervalForResource = AppConstants.edgeTTSSynthesisDeadline
        session = URLSession(configuration: sessionConfig)
    }

    enum EdgeTTSError: LocalizedError {
        case connectionFailed(String)
        case synthesisTimedOut
        case noAudioReceived
        case unexpectedMessage(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let message):
                return "Edge TTS connection failed: \(message)"
            case .synthesisTimedOut:
                return "Edge TTS synthesis request timed out"
            case .noAudioReceived:
                return "No audio data received from Edge TTS"
            case .unexpectedMessage(let message):
                return "Unexpected message from Edge TTS: \(message)"
            }
        }
    }

    func synthesize(text: String, voice: TTSVoice, rate: PlaybackRate) async throws -> SynthesizedAudio {
        let token = EdgeTTSProtocol.generateSecMsGec()
        let url = EdgeTTSProtocol.buildWebSocketURL(token: token)

        var request = URLRequest(url: url)
        // Headers must match what the Edge browser extension sends — server validates all of these
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let webSocket = session.webSocketTask(with: request)
        webSocket.resume()

        defer { webSocket.cancel() }

        do {
            let configMessage = EdgeTTSProtocol.buildConfigMessage()
            try await webSocket.send(.string(configMessage))
            logger.debug("Sent config message to Edge TTS")

            let ssml = EdgeTTSProtocol.buildSSML(text: text, voice: voice.rawValue, rate: rate.ssmlRate)
            let synthesisMessage = EdgeTTSProtocol.buildSynthesisMessage(ssml: ssml)
            try await webSocket.send(.string(synthesisMessage))
            logger.debug("Sent synthesis message to Edge TTS")

            var audioBuffer = Data()
            var wordBoundaries: [WordBoundary] = []
            var receivingAudio = true

            while receivingAudio {
                let message = try await webSocket.receive()

                switch message {
                case .string(let stringMessage):
                    logger.debug("Received string message")
                    if stringMessage.contains("Path:audio.metadata") {
                        wordBoundaries.append(contentsOf: Self.parseWordBoundaries(from: stringMessage))
                    } else if stringMessage.contains("Path:turn.end") {
                        logger.info("Received turn.end, stopping audio reception")
                        receivingAudio = false
                    }

                case .data(let data):
                    logger.debug("Received binary message of size: \(data.count)")
                    if let extractedAudio = extractAudioFromMessage(data) {
                        audioBuffer.append(extractedAudio)
                    }

                @unknown default:
                    logger.error("Received unknown message type")
                }
            }

            guard !audioBuffer.isEmpty else {
                logger.error("No audio data received from Edge TTS")
                throw EdgeTTSError.noAudioReceived
            }

            logger.info("Edge TTS synthesis succeeded: \(audioBuffer.count) bytes, \(wordBoundaries.count) word boundaries")
            return SynthesizedAudio(data: audioBuffer, wordBoundaries: wordBoundaries)
        } catch let error as EdgeTTSError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            logger.error("Edge TTS synthesis timed out")
            throw EdgeTTSError.synthesisTimedOut
        } catch {
            let detail: String
            if let urlError = error as? URLError {
                detail = "URLError \(urlError.code.rawValue): \(urlError.localizedDescription)"
            } else {
                detail = "\(type(of: error)): \(error.localizedDescription)"
            }
            logger.error("Edge TTS synthesis failed — \(detail)")
            throw EdgeTTSError.connectionFailed(detail)
        }
    }

    // MARK: - Metadata Parsing

    /// The JSON body of a `Path:audio.metadata` message. Offsets/durations are
    /// in 100-nanosecond ticks relative to the start of the audio stream.
    private struct MetadataPayload: Decodable {
        let metadata: [Entry]

        enum CodingKeys: String, CodingKey {
            case metadata = "Metadata"
        }

        struct Entry: Decodable {
            let type: String
            let data: EntryData?

            enum CodingKeys: String, CodingKey {
                case type = "Type"
                case data = "Data"
            }
        }

        struct EntryData: Decodable {
            let offset: Double
            let duration: Double?
            let text: TextInfo

            enum CodingKeys: String, CodingKey {
                case offset = "Offset"
                case duration = "Duration"
                case text
            }
        }

        struct TextInfo: Decodable {
            let text: String

            enum CodingKeys: String, CodingKey {
                case text = "Text"
            }
        }
    }

    private static func parseWordBoundaries(from message: String) -> [WordBoundary] {
        guard let bodyStart = message.range(of: "\r\n\r\n")?.upperBound,
              let body = message[bodyStart...].data(using: .utf8),
              let payload = try? JSONDecoder().decode(MetadataPayload.self, from: body)
        else {
            return []
        }

        let ticksPerSecond = 10_000_000.0
        return payload.metadata.compactMap { entry in
            guard entry.type == "WordBoundary", let data = entry.data else { return nil }
            return WordBoundary(
                time: data.offset / ticksPerSecond,
                duration: (data.duration ?? 0) / ticksPerSecond,
                text: data.text.text
            )
        }
    }

    private func extractAudioFromMessage(_ data: Data) -> Data? {
        guard data.count >= 2 else { return nil }

        let headerLength = data.withUnsafeBytes { bytes -> UInt16 in
            let b0 = bytes.load(fromByteOffset: 0, as: UInt8.self)
            let b1 = bytes.load(fromByteOffset: 1, as: UInt8.self)
            return UInt16(b0) << 8 | UInt16(b1)
        }

        let headerEndIndex = 2 + Int(headerLength)

        guard headerEndIndex < data.count else {
            return nil
        }

        let audioData = data.subdata(in: headerEndIndex..<data.count)
        return audioData.isEmpty ? nil : audioData
    }
}
