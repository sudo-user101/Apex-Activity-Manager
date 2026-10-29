import Foundation

/// A cloud folder whose contents aren't on this Mac yet (iCloud Drive, a
/// service's app). Listing one makes macOS ask the server; when the server
/// can't answer (offline, signed out) the listing waits, so walks don't go
/// inside. Its files take no space here. Reading the flag doesn't open it.
enum Dataless {
    static func folder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// A file that's only online (opening it downloads it). Reading the flag doesn't.
    static func file(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_flags & UInt32(SF_DATALESS) != 0
    }
}
