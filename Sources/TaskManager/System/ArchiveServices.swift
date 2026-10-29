import AppKit

/// Finder's right-click › Services (Quick Actions): Look Inside with Apex,
/// Extract with Apex, Compress with Apex, for the selected items. Declared in
/// Info.plist (`NSServices`); macOS lists them once Apex has run.
@MainActor
final class ArchiveServices: NSObject {
    static let shared = ArchiveServices()

    static func register() {
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices()
    }

    private func files(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @objc func lookInside(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let url = files(pb).first else { return }
        FolderPreviewPanel.shared.show(ArchiveTools.isArchive(url) || ArchiveTools.isDiskImage(url) ? url : FolderPreview.folder(for: url))
        if ArchiveTools.isDiskImage(url) { FolderPreviewPanel.shared.model.enterDiskImage(url) }
    }

    @objc func extractArchives(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let archives = files(pb).filter(ArchiveTools.isArchive)
        guard !archives.isEmpty else { error.pointee = "Choose an archive to extract." as NSString; return }
        let reveal = UserDefaults.standard.object(forKey: FolderPreview.Keys.revealAfterExtract) as? Bool ?? true
        Task {
            var made: [URL] = []
            for a in archives {
                do { made.append(try await ArchiveTools.extract(a, to: a.deletingLastPathComponent())) }
                catch ArchiveTools.Failure.needsPassword {
                    // Password archives open in the preview, which asks for it.
                    FolderPreviewPanel.shared.show(a)
                } catch {
                    QuitReminder.show("“\(a.lastPathComponent)”: \(error.localizedDescription)", plain: true)
                }
            }
            if reveal, !made.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(made) }
        }
    }

    @objc func compressItems(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let items = files(pb)
        guard !items.isEmpty else { return }
        let format = ArchiveTools.Format(rawValue: UserDefaults.standard.string(forKey: FolderPreview.Keys.newFormat) ?? "") ?? .zip
        Task {
            do {
                let made = try await ArchiveTools.create(items, format: format, password: nil, splitMB: nil)
                NSWorkspace.shared.activateFileViewerSelecting([made])
            } catch { QuitReminder.show(error.localizedDescription, plain: true) }
        }
    }
}
