import CoreAudio
import Darwin

/// Core Audio's client processes, with the process macOS holds responsible
/// for each. A process keeps its object, pid and responsible process for its
/// lifetime, so each is looked up once. Not thread-safe: the window follower
/// uses one on its own queue.
final class AudioClientProcessCatalog {
    typealias Process = WindowAudioRouteResolver.AudioClientProcess

    private var processesByObject: [AudioObjectID: Process] = [:]

    func current() -> [Process] {
        guard #available(macOS 14.2, *) else { return [] }
        var next: [AudioObjectID: Process] = [:]
        for object in ProcessAudioPlayback.processObjects() {
            if let known = processesByObject[object] {
                next[object] = known
                continue
            }
            guard let pid = CoreAudioProperty.read(from: object, selector: kAudioProcessPropertyPID, as: Int32.self),
                  pid > 0 else {
                continue
            }
            next[object] = Process(
                processID: pid,
                bundleID: ProcessAudioPlayback.string(on: object, selector: kAudioProcessPropertyBundleID),
                responsibleProcessID: ResponsibleProcess.processID(responsibleFor: pid) ?? pid
            )
        }
        processesByObject = next
        return Array(next.values)
    }
}

/// The process macOS holds responsible for another one: the app for its XPC
/// services (WebKit's GPU and web content processes) and helpers. Uses the
/// libsystem call behind Activity Monitor's grouping and TCC's attribution;
/// it has no public header, so it is looked up at run time.
enum ResponsibleProcess {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t

    private static let lookup: Lookup? = {
        // RTLD_DEFAULT is a C macro that Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    static func processID(responsibleFor pid: pid_t) -> pid_t? {
        guard let lookup else { return nil }
        let responsible = lookup(pid)
        return responsible > 0 ? responsible : nil
    }
}
