import Foundation
import os

actor EdgeTTSService {
    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "EdgeTTSService")

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

    func synthesize(text: String, voice: TTSVoice, rate: PlaybackRate) async throws -> Data {
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

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: sessionConfig)
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
            var receivingAudio = true

            while receivingAudio {
                let message = try await webSocket.receive()

                switch message {
                case .string(let stringMessage):
                    logger.debug("Received string message")
                    if stringMessage.contains("Path:turn.end") {
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

            logger.info("Edge TTS synthesis succeeded, received \(audioBuffer.count) bytes of audio")
            return audioBuffer
        } catch let error as EdgeTTSError {
            throw error
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
