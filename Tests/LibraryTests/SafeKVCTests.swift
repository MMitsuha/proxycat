import Foundation
import Testing
@testable import Library

private final class KVCSocket: NSObject {
    @objc var fileDescriptor: Int32 = 42
}

private final class KVCFixture: NSObject {
    @objc var socket: KVCSocket?
}

@Suite struct SafeKVCTests {
    @Test func resolvesNestedProperty() {
        let fixture = KVCFixture()
        fixture.socket = KVCSocket()

        let value = SafeKVC.value(forKeyPath: "socket.fileDescriptor", on: fixture)

        #expect((value as? NSNumber)?.int32Value == 42)
    }

    @Test func missingTopLevelKeyReturnsNilInsteadOfTrapping() {
        #expect(SafeKVC.value(forKeyPath: "missing.fileDescriptor", on: KVCFixture()) == nil)
    }

    @Test func missingNestedKeyReturnsNilInsteadOfTrapping() {
        let fixture = KVCFixture()
        fixture.socket = KVCSocket()

        #expect(SafeKVC.value(forKeyPath: "socket.missing", on: fixture) == nil)
    }

    @Test func nilIntermediateValueReturnsNil() {
        #expect(SafeKVC.value(forKeyPath: "socket.fileDescriptor", on: KVCFixture()) == nil)
    }
}
