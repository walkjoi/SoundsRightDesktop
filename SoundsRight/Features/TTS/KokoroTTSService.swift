import Foundation
import os

actor KokoroTTSService {
    private let session = URLSession.shared
    private var serverProcess: Process?
    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "KokoroTTSService")

    enum KokoroError: LocalizedError {
        case serverNotRunning
        case synthesisTimedOut
        case synthesisError(String)

        var errorDescription: String? {
            switch self {
            case .serverNotRunning:
                return "Kokoro server is not running"
            case .synthesisTimedOut:
                return "Kokoro synthesis request timed out"
            case .synthesisError(let message):
                return "Kokoro synthesis error: \(message)"
            }
        }
    }

    func startServer() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        guard let scriptPath = Bundle.main.path(forResource: "kokoro_server", ofType: "py") else {
            logger.error("Kokoro server script not found in app bundle")
            throw KokoroError.serverNotRunning
        }

        process.arguments = ["python3", scriptPath]
        process.environment = ["PYTHONUNBUFFERED": "1"]

        do {
            try process.run()
            self.serverProcess = process
            logger.info("Kokoro server process started")

            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            logger.error("Failed to start Kokoro server: \(error.localizedDescription)")
            throw KokoroError.serverNotRunning
        }
    }

    func stopServer() {
        guard let process = serverProcess else { return }
        if process.isRunning {
            process.terminate()
            logger.info("Kokoro server process terminated")
        }
        serverProcess = nil
    }

    func isServerRunning() async -> Bool {
        let healthURL = URL(string: "http://127.0.0.1:18923/health")!
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1.0

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            logger.debug("Health check failed: \(error.localizedDescription)")
            return false
        }
    }

    func synthesize(text: String, speed: Double, voice: String = "af_heart") async throws -> Data {
        let request = buildSynthesisRequest(text: text, speed: speed, voice: voice)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw KokoroError.synthesisError("Invalid response")
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw KokoroError.synthesisError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }

            logger.info("Kokoro synthesis succeeded for text length: \(text.count)")
            return data
        } catch let error as KokoroError {
            throw error
        } catch {
            logger.error("Kokoro synthesis failed: \(error.localizedDescription)")
            throw KokoroError.synthesisError(error.localizedDescription)
        }
    }

    private func buildSynthesisRequest(text: String, speed: Double, voice: String) -> URLRequest {
        guard let url = URL(string: AppConstants.kokoroServerURL) else {
            return URLRequest(url: URL(string: "http://127.0.0.1:18923/tts")!)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        let payload: [String: Any] = [
            "text": text,
            "speed": speed,
            "voice": voice
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            logger.error("Failed to serialize request payload: \(error.localizedDescription)")
        }

        return request
    }
}
