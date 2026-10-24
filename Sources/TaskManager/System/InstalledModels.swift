import Foundation

/// Models downloaded on this Mac, found by scanning each runtime's model
/// folder. Runs in the background when the Local AI view opens; results are
/// cached for the session.
struct InstalledModel: Identifiable, Sendable, Hashable {
    var id: String { path }
    let name: String
    let source: String       // "LM Studio", "Ollama", "Hugging Face"
    let format: String       // "MLX", "GGUF", "Ollama", "Safetensors"
    let sizeBytes: UInt64
    let path: String
}

enum InstalledModels {
    static func scan() -> [InstalledModel] {
        let home = NSHomeDirectory()
        var out: [InstalledModel] = []
        for root in [home + "/.lmstudio/models", home + "/.cache/lm-studio/models"] {
            out += lmStudio(root)
        }
        out += ollama(home + "/.ollama/models")
        out += huggingFace(home + "/.cache/huggingface/hub")
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// <root>/<publisher>/<model>/ — a folder of MLX/safetensors weights, or
    /// one or more .gguf files (each one a model).
    private static func lmStudio(_ root: String) -> [InstalledModel] {
        let fm = FileManager.default
        var out: [InstalledModel] = []
        for publisher in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !publisher.hasPrefix(".") {
            let pdir = root + "/" + publisher
            for model in (try? fm.contentsOfDirectory(atPath: pdir)) ?? [] where !model.hasPrefix(".") {
                let mdir = pdir + "/" + model
                let files = (try? fm.contentsOfDirectory(atPath: mdir)) ?? []
                let ggufs = files.filter { $0.lowercased().hasSuffix(".gguf") && !$0.lowercased().hasPrefix("mmproj") }
                if !ggufs.isEmpty {
                    for g in ggufs {
                        let p = mdir + "/" + g
                        out.append(.init(name: String(g.dropLast(5)), source: "LM Studio", format: "GGUF",
                                         sizeBytes: fileSize(p), path: p))
                    }
                } else if files.contains(where: { $0.hasSuffix(".safetensors") }) {
                    let format = model.uppercased().contains("MLX") || publisher.lowercased().contains("mlx") ? "MLX" : "Safetensors"
                    out.append(.init(name: model, source: "LM Studio", format: format,
                                     sizeBytes: folderSize(mdir), path: mdir))
                }
            }
        }
        return out
    }

    /// manifests/<registry>/<namespace>/<model>/<tag> (JSON listing layer sizes).
    private static func ollama(_ root: String) -> [InstalledModel] {
        let fm = FileManager.default
        let manifests = root + "/manifests"
        guard let e = fm.enumerator(atPath: manifests) else { return [] }
        var out: [InstalledModel] = []
        while let rel = e.nextObject() as? String {
            let p = manifests + "/" + rel
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
                  let d = fm.contents(atPath: p),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let layers = j["layers"] as? [[String: Any]] else { continue }
            let parts = rel.split(separator: "/")
            guard parts.count >= 3 else { continue }
            let ns = parts[parts.count - 3], model = parts[parts.count - 2], tag = parts[parts.count - 1]
            let name = (ns == "library" ? "" : "\(ns)/") + "\(model):\(tag)"
            let size = layers.reduce(UInt64(0)) { $0 + (($1["size"] as? NSNumber)?.uint64Value ?? 0) }
            out.append(.init(name: name, source: "Ollama", format: "Ollama", sizeBytes: size, path: p))
        }
        return out
    }

    /// models--<org>--<name> folders that contain model weights.
    private static func huggingFace(_ root: String) -> [InstalledModel] {
        let fm = FileManager.default
        var out: [InstalledModel] = []
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where dir.hasPrefix("models--") {
            let p = root + "/" + dir
            let size = folderSize(p + "/blobs")
            guard size > 50 << 20 else { continue }   // skip tokenizers / tiny repos
            let name = dir.dropFirst(8).replacingOccurrences(of: "--", with: "/")
            out.append(.init(name: name, source: "Hugging Face",
                             format: name.lowercased().contains("mlx") ? "MLX" : "Safetensors",
                             sizeBytes: size, path: p))
        }
        return out
    }

    private static func fileSize(_ p: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func folderSize(_ p: String) -> UInt64 {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: p),
                                                     includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += UInt64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
