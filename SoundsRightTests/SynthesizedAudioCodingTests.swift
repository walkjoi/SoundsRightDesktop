import XCTest
@testable import SoundsRight

/// The disk cache's binary container. Audio bytes are stored verbatim rather
/// than base64'd through JSON, so the framing is ours to get right — including
/// rejecting anything malformed as a cache miss instead of trusting it.
final class SynthesizedAudioCodingTests: XCTestCase {

    private func roundTrip(_ audio: SynthesizedAudio) -> SynthesizedAudio? {
        SynthesizedAudio.decodedFromDisk(audio.encodedForDisk())
    }

    func testRoundTripsAudioAndBoundaries() {
        let audio = SynthesizedAudio(
            data: Data((0..<4096).map { UInt8($0 % 256) }),
            wordBoundaries: [
                WordBoundary(time: 0, duration: 0.31, text: "Hello"),
                WordBoundary(time: 0.42, duration: 0.25, text: "world"),
                // Non-ASCII must survive the UTF-8 length framing.
                WordBoundary(time: 0.9, duration: 0.4, text: "naïve — 声")
            ]
        )

        let decoded = roundTrip(audio)
        XCTAssertEqual(decoded?.data, audio.data)
        XCTAssertEqual(decoded?.wordBoundaries, audio.wordBoundaries)
    }

    /// Edge sends no metadata for some voices, and the fallback path produces
    /// none at all; an entry with no timings still has to cache.
    func testRoundTripsWithoutBoundaries() {
        let audio = SynthesizedAudio(data: Data([1, 2, 3]), wordBoundaries: [])
        let decoded = roundTrip(audio)
        XCTAssertEqual(decoded?.data, audio.data)
        XCTAssertEqual(decoded?.wordBoundaries, [])
    }

    func testEmptyPayloadRoundTrips() {
        let decoded = roundTrip(SynthesizedAudio(data: Data(), wordBoundaries: []))
        XCTAssertEqual(decoded?.data, Data())
        XCTAssertEqual(decoded?.wordBoundaries, [])
    }

    /// Boundary times are doubles; the framing must not round them.
    func testBoundaryTimesSurviveExactly() {
        let time = 12.3456789
        let audio = SynthesizedAudio(
            data: Data([0]),
            wordBoundaries: [WordBoundary(time: time, duration: 1.0 / 3.0, text: "x")]
        )
        let decoded = roundTrip(audio)
        XCTAssertEqual(decoded?.wordBoundaries.first?.time, time)
        XCTAssertEqual(decoded?.wordBoundaries.first?.duration, 1.0 / 3.0)
    }

    func testRejectsForeignData() {
        // A file left behind by the superseded JSON format.
        let json = Data(#"{"data":"AAEC","wordBoundaries":[]}"#.utf8)
        XCTAssertNil(SynthesizedAudio.decodedFromDisk(json))
        XCTAssertNil(SynthesizedAudio.decodedFromDisk(Data()))
        XCTAssertNil(SynthesizedAudio.decodedFromDisk(Data([0x53, 0x52])))
    }

    /// A write interrupted partway through must read back as a miss, not as a
    /// truncated entry or a crash.
    func testRejectsTruncatedData() {
        let encoded = SynthesizedAudio(
            data: Data(repeating: 7, count: 512),
            wordBoundaries: [WordBoundary(time: 1, duration: 1, text: "word")]
        ).encodedForDisk()

        for length in stride(from: 0, to: encoded.count, by: 7) {
            XCTAssertNil(
                SynthesizedAudio.decodedFromDisk(encoded.prefix(length)),
                "A \(length)-byte prefix of a \(encoded.count)-byte entry decoded as valid"
            )
        }
    }

    /// The point of the format: the payload is the audio, not a base64 copy of it.
    func testEncodingDoesNotInflateTheAudioPayload() {
        let audioByteCount = 64 * 1024
        let encoded = SynthesizedAudio(
            data: Data(repeating: 0xAB, count: audioByteCount),
            wordBoundaries: []
        ).encodedForDisk()

        XCTAssertLessThan(encoded.count, audioByteCount + 64)
    }
}
