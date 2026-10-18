import Darwin
import Foundation
import HookCore

/// The app's end of approving permission prompts from the bubble: listens on ~/.claude-bubble/approve.sock, where
/// each waiting hook connects and sends its `ApprovalRequest`. A request stays pending until the user clicks Allow or
/// Deny (the reply goes back over that same connection), or the hook hangs up (answered in the terminal, or gave up).
final class ApprovalServer {
    /// The pending requests, oldest first; delivered on the main thread.
    var onChange: (([ApprovalRequest]) -> Void)?

    private let path: String
    private let queue = DispatchQueue(label: "com.claudebubble.approvals")
    private var listener: DispatchSourceRead?
    /// Per connection: its reader, what it has sent so far, and its request once that's arrived.
    private var connections: [Int32: (source: DispatchSourceRead, buffer: Data, request: ApprovalRequest?)] = [:]
    private var order: [Int32] = []

    init(directory: URL) {
        path = directory.appendingPathComponent(Approval.socketName).path
    }

    var isRunning: Bool { queue.sync { listener != nil } }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let fd = UnixSocket.listen(path) else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            listener = source
        }
    }

    /// Stops listening: hooks waiting now get no decision (their terminal prompts stand), and new ones don't wait.
    func stop() {
        queue.async { [self] in
            guard let listener else { return }
            listener.cancel()
            self.listener = nil
            unlink(path)
            for fd in order { drop(fd) }
            publish()
        }
    }

    /// The user's click: sent to the hook that asked, which hands it to Claude Code.
    func reply(_ id: String, _ behavior: ApprovalBehavior, answers: [String: String]? = nil) {
        queue.async { [self] in
            guard let fd = order.first(where: { connections[$0]?.request?.id == id }) else { return }
            UnixSocket.write(fd, Approval.line(ApprovalReply(id: id, behavior: behavior, answers: answers)))
            drop(fd)
            publish()
        }
    }

    private func accept(_ listenFD: Int32) {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // Only this user's own processes (the hook) may ask.
        guard UnixSocket.peerIsSelf(fd) else { close(fd); return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read(fd) }
        source.setCancelHandler { close(fd) }
        connections[fd] = (source, Data(), nil)
        order.append(fd)
        source.resume()
    }

    private func read(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(fd, &chunk, chunk.count)
        guard n > 0, var connection = connections[fd] else {
            // The hook hung up: the prompt was answered in the terminal, or the hook gave up.
            drop(fd)
            publish()
            return
        }
        guard connection.request == nil else { return }   // one request per connection; nothing else is expected
        connection.buffer.append(contentsOf: chunk[0..<n])
        if let end = connection.buffer.firstIndex(of: 0x0A) {
            connection.request = try? JSONDecoder().decode(ApprovalRequest.self, from: connection.buffer[..<end])
            connection.buffer = Data()
            connections[fd] = connection
            if connection.request == nil { drop(fd) }
            publish()
        } else if connection.buffer.count > 1 << 20 {
            drop(fd)
        } else {
            connections[fd] = connection
        }
    }

    private func drop(_ fd: Int32) {
        connections.removeValue(forKey: fd)?.source.cancel()
        order.removeAll { $0 == fd }
    }

    private func publish() {
        let pending = order.compactMap { connections[$0]?.request }
        DispatchQueue.main.async { [weak self] in self?.onChange?(pending) }
    }
}
