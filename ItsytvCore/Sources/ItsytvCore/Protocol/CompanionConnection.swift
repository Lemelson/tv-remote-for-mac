import Foundation
import Network
import os.log

private let log = CoreLog(category: "Connection")

/// Manages a TCP connection to an Apple TV's Companion Link service.
/// Handles frame parsing, encryption, and request/response correlation.
///
/// Commands are sent from the main thread, global queues (button release, swipes)
/// and the keep-alive timer at once. `lock` guards everything a send touches: the
/// encrypt nonce must match the order frames reach the wire, or the Apple TV fails
/// to decrypt and drops the link. Receiving runs on the private serial `queue`.
final class CompanionConnection {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.itsytv.companion", qos: .userInitiated)
    private var connection: NWConnection?
    private var buffer = Data()
    private var crypto: CompanionCrypto?
    private var nextXID: Int64
    private var pendingResponses: [Int64: (OPACK.Value) -> Void] = [:]
    private var keepAliveTimer: DispatchSourceTimer?
    /// Set once the link is gone (or closed by us): `onDisconnect` fires at most once,
    /// even though a drop shows up both as a receive error and as a `.failed` state.
    private var isClosed = false
    var touchBaseTimestamp: TimeInterval = 0

    var onFrame: ((CompanionFrame) -> Void)?
    var onConnect: (() -> Void)?
    var onDisconnect: ((Swift.Error?) -> Void)?
    /// The system blocks local network access for this app. The connection keeps waiting and
    /// goes on by itself (`onConnect`) once the user allows access.
    var onLocalNetworkDenied: (() -> Void)?

    init() {
        nextXID = Int64.random(in: 1...10000)
    }

    deinit {
        keepAliveTimer?.cancel()
        connection?.cancel()
    }

    /// Whether a connection waits because local network access is denied – either the path
    /// says so or the Bonjour resolve was refused (TN3179, "Check for local network access").
    static func isLocalNetworkDenied(_ error: NWError, unsatisfiedReason: NWPath.UnsatisfiedReason?) -> Bool {
        if case .localNetworkDenied? = unsatisfiedReason { return true }
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return true }
        return false
    }

    func connect(to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                log.info("Connection ready")
                self?.onConnect?()
                self?.startReceiving()
            case .waiting(let error):
                guard Self.isLocalNetworkDenied(error, unsatisfiedReason: connection?.currentPath?.unsatisfiedReason) else {
                    log.info("Connection waiting: \(error.localizedDescription)")
                    return
                }
                log.warning("Local network access denied – waiting for the user to allow it")
                self?.onLocalNetworkDenied?()
            case .failed(let error):
                self?.reportDisconnect(error)
            case .cancelled:
                self?.reportDisconnect(nil)
            default:
                break
            }
        }

        lock.withLock {
            self.connection = connection
            isClosed = false
        }
        connection.start(queue: queue)
    }

    func connect(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        connect(to: endpoint)
    }

    func connectToService(name: String) {
        log.info("Connecting to service \(name)")
        let endpoint = NWEndpoint.service(
            name: name,
            type: "_companion-link._tcp",
            domain: "local.",
            interface: nil
        )
        connect(to: endpoint)
    }

    /// Close the link on purpose: `onDisconnect` is not called.
    func disconnect() {
        close()
    }

    /// The link dropped: close it for good (the old `NWConnection` is cancelled, not
    /// left hanging) and tell the owner once.
    private func reportDisconnect(_ error: Swift.Error?) {
        guard close() else { return }
        onDisconnect?(error)
    }

    /// Returns false when already closed.
    @discardableResult
    private func close() -> Bool {
        let (wasOpen, nw): (Bool, NWConnection?) = lock.withLock {
            guard !isClosed else { return (false, nil) }
            isClosed = true
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
            let nw = connection
            connection = nil
            crypto = nil
            pendingResponses.removeAll()
            return (true, nw)
        }
        guard wasOpen else { return false }
        nw?.cancel()
        queue.async { self.buffer = Data() }
        return true
    }

    func enableEncryption(_ crypto: CompanionCrypto) {
        lock.withLock { self.crypto = crypto }
    }

    /// Start sending periodic NoOp frames to keep the connection alive.
    func startKeepAlive(interval: TimeInterval = 30) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            log.debug("Sending keep-alive NoOp")
            self?.send(frame: CompanionFrame(type: .noOp, payload: Data()))
        }
        // Resume before handing it over: a dispatch source released while suspended crashes.
        timer.resume()
        lock.withLock {
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
            if isClosed { timer.cancel() } else { keepAliveTimer = timer }
        }
    }

    func stopKeepAlive() {
        lock.withLock {
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
        }
    }


    /// Send a raw frame. If encryption is active, encrypts the payload.
    func send(frame: CompanionFrame, completion: ((Swift.Error?) -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        sendLocked(frame: frame, completion: completion)
    }

    /// Encrypt and hand the frame to the network in one critical section, so nonce
    /// order and wire order agree. `NWConnection.send` only enqueues, it never blocks.
    private func sendLocked(frame: CompanionFrame, completion: ((Swift.Error?) -> Void)?) {
        log.debug("Sending frame: type=\(String(describing: frame.type)) payload=\(frame.payload.count) bytes")
        guard let connection else {
            if let completion { DispatchQueue.global().async { completion(nil) } }
            return
        }
        var wireData: Data

        if let crypto, !frame.payload.isEmpty {
            // Build header with encrypted payload length (includes 16-byte tag)
            let encryptedLength = frame.payload.count + 16
            var header = Data(capacity: CompanionFrame.headerLength)
            header.append(frame.type.rawValue)
            header.append(UInt8((encryptedLength >> 16) & 0xFF))
            header.append(UInt8((encryptedLength >> 8) & 0xFF))
            header.append(UInt8(encryptedLength & 0xFF))

            do {
                let encrypted = try crypto.encrypt(frame.payload, aad: header)
                wireData = header + encrypted
            } catch {
                if let completion { DispatchQueue.global().async { completion(error) } }
                return
            }
        } else {
            wireData = frame.serialize()
        }

        connection.send(content: wireData, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    /// Send an OPACK command as an encrypted (or unencrypted) frame.
    func sendCommand(_ payload: OPACK.Value, completion: ((Swift.Error?) -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        sendCommandLocked(payload, completion: completion)
    }

    private func sendCommandLocked(_ payload: OPACK.Value, completion: ((Swift.Error?) -> Void)?) {
        let data = OPACK.pack(payload)
        let frameType: CompanionFrameType = crypto != nil ? .opackEncrypted : .opackUnencrypted
        sendLocked(frame: CompanionFrame(type: frameType, payload: data), completion: completion)
    }

    /// Send a request (type=2) with an auto-incrementing XID. Returns the XID used.
    @discardableResult
    func sendRequest(
        eventName: String? = nil,
        content: OPACK.Value? = nil,
        responseHandler: ((OPACK.Value) -> Void)? = nil,
        completion: ((Swift.Error?) -> Void)? = nil
    ) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let xid = nextXID
        nextXID += 1

        if let responseHandler, !isClosed {
            pendingResponses[xid] = responseHandler
        }

        var pairs: [(String, OPACK.Value)] = [
            ("_t", .int(CompanionMessageType.request.rawValue)),
            ("_x", .int(xid)),
        ]
        if let eventName {
            pairs.append(("_i", .string(eventName)))
        }
        if let content {
            pairs.append(("_c", content))
        }

        sendCommandLocked(.dictionary(pairs), completion: completion)
        return xid
    }

    /// Dispatch a response to its pending handler. Returns true if a handler was found.
    @discardableResult
    func dispatchResponse(xid: Int64, message: OPACK.Value) -> Bool {
        // Run the handler outside the lock: it usually sends the next command.
        guard let handler = lock.withLock({ pendingResponses.removeValue(forKey: xid) }) else {
            log.debug("No pending handler for xid=\(xid)")
            return false
        }
        log.debug("Dispatching response for xid=\(xid)")
        handler(message)
        return true
    }

    /// Send an event (type=1).
    func sendEvent(name: String, content: OPACK.Value? = nil, completion: ((Swift.Error?) -> Void)? = nil) {
        var pairs: [(String, OPACK.Value)] = [
            ("_t", .int(CompanionMessageType.event.rawValue)),
            ("_i", .string(name)),
        ]
        if let content {
            pairs.append(("_c", content))
        }
        sendCommand(.dictionary(pairs), completion: completion)
    }

    // MARK: - Receiving

    private func startReceiving() {
        let connection = lock.withLock { self.connection }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let content {
                log.debug("Received \(content.count) bytes on wire (buffer was \(self?.buffer.count ?? 0) bytes)")
                self?.buffer.append(content)
                self?.processBuffer()
            }
            if isComplete {
                log.info("Connection complete (EOF)")
                self?.reportDisconnect(nil)
            } else if let error {
                log.error("Connection error: \(error.localizedDescription)")
                self?.reportDisconnect(error)
            } else {
                self?.startReceiving()
            }
        }
    }

    private func processBuffer() {
        while true {
            guard let (frame, consumed) = CompanionFrame.parse(from: buffer) else { break }

            var processed = frame
            let crypto = lock.withLock { self.crypto }

            // Decrypt if needed
            if let crypto, !frame.payload.isEmpty,
               (frame.type == .opackEncrypted || frame.type == .pairVerifyNext || frame.type == .pairSetupNext) {
                // Reconstruct the header as AAD
                let aad = Data([
                    frame.type.rawValue,
                    UInt8((frame.payload.count >> 16) & 0xFF),
                    UInt8((frame.payload.count >> 8) & 0xFF),
                    UInt8(frame.payload.count & 0xFF),
                ])
                do {
                    let decrypted = try crypto.decrypt(frame.payload, aad: aad)
                    processed = CompanionFrame(type: frame.type, payload: decrypted)
                } catch {
                    log.error("Decrypt failed: \(error.localizedDescription)")
                }
            }

            buffer = Data(buffer.dropFirst(consumed))
            onFrame?(processed)
        }
    }
}
