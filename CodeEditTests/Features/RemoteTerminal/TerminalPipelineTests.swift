import XCTest
@testable import CodeEdit

final class TerminalPipelineTests: XCTestCase {

    // Minimal TerminalConnection that fires onDataReceived manually.
    final class MockConnection: TerminalConnection {
        let id = UUID()
        var isConnected = true
        var onDataReceived: ((ArraySlice<UInt8>) -> Void)?
        var onTerminated: ((Int32?) -> Void)?
        func connect() async throws {}
        func disconnect() { isConnected = false }
        func send(data: ArraySlice<UInt8>) {}
        func resize(cols: Int, rows: Int) {}
    }

    // Processing observer that uppercases ASCII bytes.
    final class UppercaseObserver: TerminalProcessingObserver {
        func process(bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
            Array(bytes.map { ($0 >= 97 && $0 <= 122) ? $0 - 32 : $0 })[...]
        }
    }

    // Notifying observer that captures received text.
    final class CapturingObserver: TerminalNotifyingObserver {
        var received: [String] = []
        var terminatedWith: Int32?? = .none  // .none = never called, .some(nil) = called with nil
        func connectionDidReceive(text: String) { received.append(text) }
        func connectionDidTerminate(exitCode: Int32?) { terminatedWith = .some(exitCode) }
    }

    func test_bytesDeliveredToFeedCallback() {
        let connection = MockConnection()
        var fed: [UInt8] = []
        let pipeline = TerminalPipeline(connection: connection) { bytes in
            fed.append(contentsOf: bytes)
        }

        let input: ArraySlice<UInt8> = [72, 105][...]  // "Hi"
        connection.onDataReceived?(input)

        XCTAssertEqual(fed, [72, 105])
        _ = pipeline  // keep alive
    }

    func test_processingObserverTransformsBytes() {
        let connection = MockConnection()
        var fed: [UInt8] = []
        let pipeline = TerminalPipeline(connection: connection) { bytes in
            fed.append(contentsOf: bytes)
        }
        pipeline.processingObservers.append(UppercaseObserver())

        let input: ArraySlice<UInt8> = Array("hello".utf8)[...]
        connection.onDataReceived?(input)

        XCTAssertEqual(String(bytes: fed, encoding: .utf8), "HELLO")
        _ = pipeline
    }

    func test_notifyingObserverReceivesPlainText() {
        let connection = MockConnection()
        let notifier = CapturingObserver()
        let pipeline = TerminalPipeline(connection: connection) { _ in }
        pipeline.notifyingObservers.append(notifier)

        // Input with ANSI color code wrapping "OK"
        let input: [UInt8] = Array("\u{1B}[32mOK\u{1B}[0m".utf8)
        connection.onDataReceived?(input[...])

        XCTAssertEqual(notifier.received, ["OK"])
        _ = pipeline
    }

    func test_terminationForwardedToNotifyingObservers() {
        let connection = MockConnection()
        let notifier = CapturingObserver()
        let pipeline = TerminalPipeline(connection: connection) { _ in }
        pipeline.notifyingObservers.append(notifier)

        connection.onTerminated?(42)

        XCTAssertEqual(notifier.terminatedWith, .some(42))
        _ = pipeline
    }
}
