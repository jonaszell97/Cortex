import CoreServices
import Foundation

/// Calls back on the main thread when anything in a directory changes,
/// including files edited in place (which a plain directory watch misses).
@MainActor
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let box: CallbackBox

    private final class CallbackBox {
        let onChange: @MainActor ([String]) -> Void
        init(_ onChange: @escaping @MainActor ([String]) -> Void) { self.onChange = onChange }
    }

    convenience init?(url: URL, latency: TimeInterval = 0.3, onChange: @escaping @MainActor () -> Void) {
        self.init(url: url, latency: latency, onChangeAt: { _ in onChange() })
    }

    /// `onChangeAt` gets the absolute paths that changed (several events
    /// within `latency` arrive together).
    init?(url: URL, latency: TimeInterval = 0.3, onChangeAt: @escaping @MainActor ([String]) -> Void) {
        box = CallbackBox(onChangeAt)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes: a CFArray of CFStrings.
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let changed = (0..<count).compactMap { array[$0] as? String }
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated { box.onChange(changed) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
