import Foundation

/// Watches files and directories with vnode DispatchSources and reports
/// changed URLs in debounced batches.
///
/// A watched directory reports when entries are added, removed or renamed
/// inside it (not when a file inside is merely written); a watched file
/// reports writes, renames and deletion. When a watched item is deleted or
/// renamed its source is torn down and its parent directory is reported, so
/// the tree can reload that level.
public final class FileWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (Set<URL>) -> Void

    private let queue: DispatchQueue
    private let debounce: DispatchTimeInterval
    private let handler: Handler
    private let lock = NSLock()
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: Set<URL> = []
    private var flushScheduled = false

    public init(debounce: DispatchTimeInterval = .milliseconds(120),
                queue: DispatchQueue = DispatchQueue(label: "com.geramyloveless.LemonSeedStudio.filewatcher", qos: .utility),
                handler: @escaping Handler) {
        self.queue = queue
        self.debounce = debounce
        self.handler = handler
    }

    deinit {
        for source in sources.values { source.cancel() }
    }

    /// The paths currently watched.
    public var watchedPaths: Set<String> {
        lock.withLock { Set(sources.keys) }
    }

    /// Starts watching `url`. Returns false if it could not be opened.
    @discardableResult
    public func watch(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if lock.withLock({ sources[path] != nil }) { return true }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .link, .revoke],
            queue: queue)
        let watched = URL(fileURLWithPath: path)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                self.stop(path: path)
                self.enqueue([watched, watched.deletingLastPathComponent()])
            } else {
                self.enqueue([watched])
            }
        }
        source.setCancelHandler { close(fd) }
        let inserted: Bool = lock.withLock {
            if sources[path] != nil { return false }
            sources[path] = source
            return true
        }
        source.resume()
        if !inserted {
            // Another thread watched the same path first; drop this one.
            source.cancel()
        }
        return true
    }

    public func unwatch(_ url: URL) {
        stop(path: url.standardizedFileURL.path)
    }

    /// Stops watching `url` and everything beneath it.
    public func unwatchTree(_ url: URL) {
        let root = url.standardizedFileURL.path
        let doomed: [DispatchSourceFileSystemObject] = lock.withLock {
            let keys = sources.keys.filter { $0 == root || $0.hasPrefix(root + "/") }
            return keys.compactMap { sources.removeValue(forKey: $0) }
        }
        doomed.forEach { $0.cancel() }
    }

    public func unwatchAll() {
        let all: [DispatchSourceFileSystemObject] = lock.withLock {
            defer { sources.removeAll() }
            return Array(sources.values)
        }
        all.forEach { $0.cancel() }
    }

    private func stop(path: String) {
        let source = lock.withLock { sources.removeValue(forKey: path) }
        source?.cancel()
    }

    private func enqueue(_ urls: [URL]) {
        let schedule: Bool = lock.withLock {
            pending.formUnion(urls)
            if flushScheduled { return false }
            flushScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            let batch: Set<URL> = self.lock.withLock {
                defer {
                    self.pending.removeAll()
                    self.flushScheduled = false
                }
                return self.pending
            }
            if !batch.isEmpty { self.handler(batch) }
        }
    }
}
