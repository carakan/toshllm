// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One recursive inventory shared by LLM, image and video model detection.
struct ModelFileIndex: Sendable {
    private static let modelExtensions: Set<String> = ["gguf", "safetensors", "ckpt", "pth", "pt", "bin"]
    /// Small files that go with a model rather than being one, e.g. the
    /// tokenizer.json Qwen3.5 needs. They stay out of the model list.
    private static let sidecarExtensions: Set<String> = ["json"]
    let root: URL
    let files: [URL]
    private let filesByName: [String: [URL]]
    private let filesByPortableName: [String: [URL]]
    private let sidecarsByName: [String: [URL]]

    init(root: URL, files: [URL], sidecars: [URL] = []) {
        self.root = root.standardizedFileURL
        self.files = files
        self.filesByName = Dictionary(grouping: files) {
            Self.key($0.lastPathComponent)
        }
        self.filesByPortableName = Dictionary(grouping: files) {
            Self.portableKey($0.lastPathComponent)
        }
        self.sidecarsByName = Dictionary(grouping: sidecars) {
            Self.key($0.lastPathComponent)
        }
    }

    static func scan(in root: URL) -> ModelFileIndex {
        let root = root.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ModelFileIndex(root: root, files: []) }

        var files: [URL] = []
        var sidecars: [URL] = []
        for case let url as URL in enumerator {
            // A model can be a symlink into the central store. The resource
            // values of a symlink describe the link itself, not the file it
            // points at, so resolve it first: otherwise isRegularFile comes
            // back false and the size is the length of the link target, and
            // the model reads as missing.
            let resolved = url.resolvingSymlinksInPath()
            guard let values = try? resolved.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) > 0 else { continue }
            let ext = url.pathExtension.lowercased()
            if modelExtensions.contains(ext) {
                files.append(url.standardizedFileURL)
            } else if sidecarExtensions.contains(ext) {
                sidecars.append(url.standardizedFileURL)
            }
        }
        return ModelFileIndex(root: root, files: files, sidecars: sidecars)
    }

    /// Basename match anywhere below the models root. The managed media folder
    /// wins when duplicate copies exist, followed by the shallowest path.
    func file(named name: String, preferredDirectory: URL? = nil) -> URL? {
        guard !name.isEmpty else { return nil }
        let exact = filesByName[Self.key(name)] ?? []
        // Mirrors sometimes move dots, dashes or underscores in an otherwise
        // identical filename. Reuse it only when every letter and digit matches.
        let candidates = exact.isEmpty ? (filesByPortableName[Self.portableKey(name)] ?? []) : exact
        let preferred = preferredDirectory?.standardizedFileURL.path
        return candidates.min { lhs, rhs in
            let left = rank(lhs, exactName: name, preferredDirectory: preferred)
            let right = rank(rhs, exactName: name, preferredDirectory: preferred)
            if left.preferred != right.preferred { return left.preferred < right.preferred }
            if left.exactCase != right.exactCase { return left.exactCase < right.exactCase }
            if left.depth != right.depth { return left.depth < right.depth }
            return left.path < right.path
        }
    }

    /// Tries canonical and source filenames in priority order.
    func file(namedAny names: [String], preferredDirectory: URL? = nil) -> URL? {
        for name in names {
            if let match = file(named: name, preferredDirectory: preferredDirectory) { return match }
        }
        return nil
    }

    /// A sidecar file, e.g. the tokenizer.json that goes with a text encoder.
    func sidecar(namedAny names: [String], preferredDirectory: URL? = nil) -> URL? {
        let preferred = preferredDirectory?.standardizedFileURL.path
        for name in names {
            let candidates = sidecarsByName[Self.key(name)] ?? []
            if let match = candidates.min(by: { lhs, rhs in
                let left = rank(lhs, exactName: name, preferredDirectory: preferred)
                let right = rank(rhs, exactName: name, preferredDirectory: preferred)
                if left.preferred != right.preferred { return left.preferred < right.preferred }
                if left.exactCase != right.exactCase { return left.exactCase < right.exactCase }
                if left.depth != right.depth { return left.depth < right.depth }
                return left.path < right.path
            }) {
                return match
            }
        }
        return nil
    }

    /// LLM discovery ignores ToshLLM's managed media folders, whose GGUF files
    /// are diffusion weights or conditioning encoders rather than chat models.
    var llmFiles: [URL] {
        let mediaFolders: Set<String> = ["imagen", "image", "images", "video", "videos", "whisper"]
        return files.filter { file in
            guard let first = relativeComponents(of: file).first?.lowercased() else { return true }
            return !mediaFolders.contains(first)
        }
    }

    private func rank(_ url: URL, exactName: String, preferredDirectory: String?)
        -> (preferred: Int, exactCase: Int, depth: Int, path: String) {
        let exactCase = url.lastPathComponent == exactName ? 0 : 1
        let preferred = url.deletingLastPathComponent().standardizedFileURL.path == preferredDirectory ? 0 : 1
        return (preferred, exactCase, relativeComponents(of: url).count, url.path)
    }

    private func relativeComponents(of url: URL) -> [String] {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return url.pathComponents }
        return String(url.path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
    }

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func portableKey(_ name: String) -> String {
        key(name).components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}
