//
//  DiscordIPC.swift
//  AgentCord
//
//  A hand-written Discord RPC IPC client. No third-party dependencies.
//  Implements only the subset needed for Rich Presence: socket discovery,
//  handshake, SET_ACTIVITY, and clearing. All socket I/O runs off the main
//  thread.
//
//  Frame format on the wire:
//    [ opcode: UInt32 LE ][ payloadLength: UInt32 LE ][ JSON bytes ]
//

import Foundation

final class DiscordIPC {

    enum State: Equatable, CustomStringConvertible {
        case disconnected
        case connecting
        case connected

        var description: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            }
        }
    }

    private enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    enum IPCError: Error {
        case writeFailed
        case encodeFailed
    }

    // MARK: Public callbacks (delivered on the main queue)

    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?

    private(set) var state: State = .disconnected

    // MARK: Internals

    private let ioQueue = DispatchQueue(label: "com.agentcord.ipc.io")
    private let readQueue = DispatchQueue(label: "com.agentcord.ipc.read", qos: .utility)

    private var fd: Int32 = -1
    private var clientID = ""
    private var shouldRun = false
    private var ready = false
    private var reconnectAttempt = 0

    /// The last non-nil activity we were asked to display. Re-sent on reconnect.
    private var currentActivity: RichPresence?

    // MARK: Public API

    /// Begin connecting (and keep reconnecting) using the given application id.
    func connect(clientID: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.clientID = clientID
            self.shouldRun = true
            self.reconnectAttempt = 0
            self.closeSocket()
            self.attemptConnect()
        }
    }

    /// Stop reconnecting, clear the presence, and close the socket.
    func disconnect() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            if self.ready { try? self.sendActivity(nil) }
            self.currentActivity = nil
            self.closeSocket()
            self.setState(.disconnected)
        }
    }

    func setActivity(_ activity: RichPresence) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.currentActivity = activity
            if self.ready { try? self.sendActivity(activity) }
        }
    }

    func clearActivity() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.currentActivity = nil
            if self.ready { try? self.sendActivity(nil) }
        }
    }

    /// Best-effort synchronous clear, used during app termination so the
    /// presence does not get stuck. Returns quickly whether or not it succeeds.
    func clearActivitySync() {
        ioQueue.sync {
            guard self.fd >= 0, self.ready else { return }
            try? self.sendActivity(nil)
        }
    }

    // MARK: Connection lifecycle (ioQueue)

    private func attemptConnect() {
        guard shouldRun else { return }
        setState(.connecting)

        guard let newFD = discoverAndConnect() else {
            scheduleReconnect()
            return
        }
        fd = newFD
        ready = false

        do {
            let payload = try JSONEncoder().encode(HandshakePayload(v: 1, client_id: clientID))
            try sendFrame(opcode: .handshake, payload: payload)
        } catch {
            closeSocket()
            scheduleReconnect()
            return
        }

        setState(.connected)
        startReadLoop(on: fd)
        // currentActivity is re-sent once we receive READY.
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        closeSocket()
        setState(.disconnected)
        reconnectAttempt += 1
        // Exponential backoff capped at 30s.
        let delay = min(pow(2.0, Double(min(reconnectAttempt, 5))), 30.0)
        ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptConnect()
        }
    }

    private func handleFrame(opcode: UInt32, data: Data) {
        switch Opcode(rawValue: opcode) {
        case .frame:
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            if let evt = obj["evt"] as? String {
                if evt == "READY" {
                    ready = true
                    reconnectAttempt = 0
                    emit { self.onReady?() }
                    if let activity = currentActivity {
                        try? sendActivity(activity)
                    }
                } else if evt == "ERROR" {
                    let message = (obj["data"] as? [String: Any])?["message"] as? String
                    emit { self.onError?(message ?? "Discord reported an error") }
                }
            }
        case .ping:
            // Reply with PONG echoing the payload.
            try? sendFrame(opcode: .pong, payload: data)
        case .close:
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = obj?["message"] as? String
            let code = obj?["code"].map { "\($0)" } ?? "?"
            emit { self.onError?(message ?? "Connection closed (code \(code))") }
            // The read loop will end and trigger a reconnect.
        default:
            break
        }
    }

    // MARK: Read loop (readQueue)

    private func startReadLoop(on socketFD: Int32) {
        readQueue.async { [weak self] in
            guard let self else { return }
            while self.shouldRun {
                guard let (opcode, payload) = self.readFrame(fd: socketFD) else { break }
                self.ioQueue.async { self.handleFrame(opcode: opcode, data: payload) }
            }
            // Socket closed or read failed.
            self.ioQueue.async {
                guard self.fd == socketFD else { return } // already replaced
                self.ready = false
                if self.shouldRun {
                    self.scheduleReconnect()
                } else {
                    self.closeSocket()
                }
            }
        }
    }

    // MARK: Framing

    private func sendActivity(_ activity: RichPresence?) throws {
        let command = SetActivityCommand(
            nonce: UUID().uuidString,
            args: SetActivityArgs(pid: ProcessInfo.processInfo.processIdentifier, activity: activity)
        )
        guard let payload = try? JSONEncoder().encode(command) else { throw IPCError.encodeFailed }
        try sendFrame(opcode: .frame, payload: payload)
    }

    private func sendFrame(opcode: Opcode, payload: Data) throws {
        guard fd >= 0 else { throw IPCError.writeFailed }
        var frame = Data(capacity: 8 + payload.count)
        var op = opcode.rawValue.littleEndian
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &op) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try writeAll(frame, fd: fd)
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var total = 0
            while total < raw.count {
                let n = Darwin.write(fd, base + total, raw.count - total)
                if n <= 0 { throw IPCError.writeFailed }
                total += n
            }
        }
    }

    private func readFrame(fd: Int32) -> (UInt32, Data)? {
        guard let header = readExact(8, fd: fd) else { return nil }
        let opcode = UInt32(header[0]) | (UInt32(header[1]) << 8) | (UInt32(header[2]) << 16) | (UInt32(header[3]) << 24)
        let length = UInt32(header[4]) | (UInt32(header[5]) << 8) | (UInt32(header[6]) << 16) | (UInt32(header[7]) << 24)
        if length == 0 { return (opcode, Data()) }
        guard let payload = readExact(Int(length), fd: fd) else { return nil }
        return (opcode, payload)
    }

    private func readExact(_ count: Int, fd: Int32) -> Data? {
        var buffer = Data(count: count)
        let ok = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var total = 0
            while total < count {
                let n = Darwin.read(fd, base + total, count - total)
                if n <= 0 { return false }
                total += n
            }
            return true
        }
        return ok ? buffer : nil
    }

    // MARK: Socket discovery / teardown

    private func discoverAndConnect() -> Int32? {
        let base = Self.tempBaseDirectory()
        for i in 0...9 {
            let path = "\(base)/discord-ipc-\(i)"
            if let socketFD = Self.openUnixSocket(path: path) {
                return socketFD
            }
        }
        return nil
    }

    private func closeSocket() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        ready = false
    }

    /// Resolve the base temp directory Discord places its socket in.
    static func tempBaseDirectory() -> String {
        let env = ProcessInfo.processInfo.environment
        for key in ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"] {
            if let value = env[key], !value.isEmpty {
                return value.hasSuffix("/") ? String(value.dropLast()) : value
            }
        }
        return "/tmp"
    }

    static func openUnixSocket(path: String) -> Int32? {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count >= capacity {
            close(socketFD)
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = byte }
                dst[pathBytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(socketFD, sa, size)
            }
        }
        if result != 0 {
            close(socketFD)
            return nil
        }
        return socketFD
    }

    // MARK: Helpers

    private func setState(_ newState: State) {
        state = newState
        emit { self.onStateChange?(newState) }
    }

    private func emit(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
