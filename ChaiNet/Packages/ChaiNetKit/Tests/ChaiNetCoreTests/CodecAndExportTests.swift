import XCTest
@testable import ChaiNetCore

final class ICMPPacketTests: XCTestCase {
    func testChecksumRFC1071Example() {
        // RFC 1071 §3 example words 0001 f203 f4f5 f6f7 → sum ddf2 → checksum 220d
        XCTAssertEqual(ICMPPacket.checksum([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]), 0x220d)
    }

    func testEchoRequestChecksumVerifies() {
        let packet = ICMPPacket.makeEchoRequest(identifier: 0xBEEF, sequence: 7, payloadSize: 33)
        XCTAssertEqual(packet.count, 8 + 33)
        XCTAssertEqual(packet[0], 8)
        XCTAssertEqual(ICMPPacket.checksum(packet), 0, "a valid packet sums to zero")
    }

    func ipHeader(src: [UInt8]) -> [UInt8] {
        [0x45, 0, 0, 0, 0, 0, 0, 0, 64, 1, 0, 0] + src + [192, 168, 1, 2]
    }

    func testParseEchoReply() {
        var reply = ICMPPacket.makeEchoRequest(identifier: 0x1234, sequence: 9, payloadSize: 4)
        reply[0] = 0
        let data = ipHeader(src: [8, 8, 8, 8]) + reply
        XCTAssertEqual(ICMPPacket.parse(data), .echoReply(identifier: 0x1234, sequence: 9))
        XCTAssertEqual(ICMPPacket.sourceAddress(data), "8.8.8.8")
    }

    func testParseTimeExceeded() {
        let original = ipHeader(src: [192, 168, 1, 2]) + ICMPPacket.makeEchoRequest(identifier: 0x1234, sequence: 3, payloadSize: 0)
        let icmp: [UInt8] = [11, 0, 0, 0, 0, 0, 0, 0] + original
        let data = ipHeader(src: [10, 0, 0, 1]) + icmp
        XCTAssertEqual(ICMPPacket.parse(data), .timeExceeded(identifier: 0x1234, sequence: 3))
        XCTAssertEqual(ICMPPacket.sourceAddress(data), "10.0.0.1")
    }

    func testParseFragmentationNeeded() {
        let original = ipHeader(src: [192, 168, 1, 2]) + ICMPPacket.makeEchoRequest(identifier: 1, sequence: 2, payloadSize: 0)
        let icmp: [UInt8] = [3, 4, 0, 0, 0, 0, 0x05, 0xDC] + original
        XCTAssertEqual(ICMPPacket.parse(ipHeader(src: [1, 1, 1, 1]) + icmp),
                       .unreachable(code: 4, identifier: 1, sequence: 2, nextHopMTU: 1500))
    }

    func testRejectsGarbage() {
        XCTAssertNil(ICMPPacket.parse([1, 2, 3]))
    }
}

final class DNSMessageTests: XCTestCase {
    func testQueryEncoding() {
        let q = DNSMessage.makeQuery(id: 0xABCD, name: "example.com", type: .a)
        XCTAssertEqual(Array(q[0..<4]), [0xAB, 0xCD, 0x01, 0x00])
        XCTAssertEqual(Array(q[12...]), [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1])
    }

    func testHeaderParsing() {
        let response: [UInt8] = [0xAB, 0xCD, 0x81, 0x83, 0, 1, 0, 2, 0, 0, 0, 0]
        let h = DNSMessage.parseHeader(response)!
        XCTAssertEqual(h.id, 0xABCD)
        XCTAssertTrue(h.isResponse)
        XCTAssertEqual(h.rcode, 3)
        XCTAssertEqual(h.answerCount, 2)
    }
}

final class ExportTests: XCTestCase {
    func sampleResult() -> TestResult {
        var r = TestResult(kind: .fullSpeedTest, network: .offline)
        r.location = GeoPoint(latitude: 25.03, longitude: 121.56, horizontalAccuracy: 10)
        r.idleLatency = LatencyStatistics.compute(from: [LatencySample(sequence: 0, offset: 0, rttMs: 12)])
        r.server = ServerDescriptor(id: "x", name: "Taipei, \"Test\"", location: "TW", kind: .chainet, baseURL: URL(string: "https://example.com")!)
        r.evaluate()
        return r
    }

    func testCSVEscaping() {
        XCTAssertEqual(ResultExporter.escape("plain"), "plain")
        XCTAssertEqual(ResultExporter.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(ResultExporter.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ResultExporter.escape("line\nbreak"), "\"line\nbreak\"")
    }

    func testCSVShape() {
        let csv = ResultExporter.csv([sampleResult()])
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], ResultExporter.csvColumns.joined(separator: ","))
        XCTAssertTrue(lines[1].contains("\"Taipei, \"\"Test\"\"\""))
    }

    func testLocationStrippedByDefault() throws {
        let data = try ResultExporter.json([sampleResult()])
        let decoded = try ResultExporter.decodeJSON(data)
        XCTAssertNil(decoded[0].location)
        let withLocation = try ResultExporter.decodeJSON(ResultExporter.json([sampleResult()], options: ExportOptions(includeLocation: true)))
        XCTAssertEqual(withLocation[0].location?.latitude, 25.03)
    }

    func testJSONRoundTrip() throws {
        let original = sampleResult()
        let decoded = try ResultExporter.decodeJSON(ResultExporter.json([original], options: ExportOptions(includeLocation: true)))
        XCTAssertEqual(decoded.first?.id, original.id)
        XCTAssertEqual(decoded.first?.idleLatency, original.idleLatency)
    }
}
