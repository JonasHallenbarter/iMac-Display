import Foundation
import Darwin

/// App mode: mirror everything written to stdout/stderr into ~/Library/Logs/iMacDisplay.log
/// (truncated on every start). If stdout is /dev/null (launched from Finder / login item) the file
/// simply replaces stdout/stderr; otherwise (e.g. started from a terminal with --app) a small
/// tee thread writes to both.
enum AppLog {
    static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/iMacDisplay.log")
    }

    private(set) static var path: String?

    static func startFileLogging(path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        self.path = path
        fflush(stdout); fflush(stderr)

        if stdoutIsDevNull() {
            dup2(fd, STDOUT_FILENO)
            dup2(fd, STDERR_FILENO)
            close(fd)
            return
        }

        let origOut = dup(STDOUT_FILENO)
        var p: [Int32] = [0, 0]
        guard pipe(&p) == 0 else {
            dup2(fd, STDERR_FILENO)
            return
        }
        dup2(p[1], STDOUT_FILENO)
        dup2(p[1], STDERR_FILENO)
        close(p[1])
        let readFD = p[0]
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                buf.withUnsafeBytes {
                    _ = write(origOut, $0.baseAddress, n)
                    _ = write(fd, $0.baseAddress, n)
                }
            }
        }
        t.name = "imac-display.log-tee"
        t.start()
    }

    private static func stdoutIsDevNull() -> Bool {
        var a = stat(), b = stat()
        guard fstat(STDOUT_FILENO, &a) == 0, stat("/dev/null", &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
}
