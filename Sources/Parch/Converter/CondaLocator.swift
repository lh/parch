import Foundation

/// Finds the conda binary used to run Python-based engines.
enum CondaLocator {
    static func find() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/conda",
            "/usr/local/bin/conda",
            home.appendingPathComponent("miniforge3/bin/conda").path,
            home.appendingPathComponent("miniconda3/bin/conda").path,
            home.appendingPathComponent("anaconda3/bin/conda").path,
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return candidates[0]
    }

    /// Whether a named conda environment exists on this machine.
    static func envExists(_ name: String) -> Bool {
        let fm = FileManager.default
        let conda = find()
        guard fm.fileExists(atPath: conda) else { return false }

        // conda maintains ~/.conda/environments.txt with one env path per line.
        let listPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".conda/environments.txt").path
        if let list = try? String(contentsOfFile: listPath, encoding: .utf8) {
            for line in list.split(separator: "\n") {
                let path = line.trimmingCharacters(in: .whitespaces)
                if path.hasSuffix("/envs/\(name)"), fm.fileExists(atPath: path) {
                    return true
                }
            }
        }

        // Fall back to the envs directory beside the resolved conda root,
        // for installs that never wrote environments.txt.
        let root = URL(fileURLWithPath: conda).resolvingSymlinksInPath()
            .deletingLastPathComponent()  // bin/
            .deletingLastPathComponent()  // <root>/
        return fm.fileExists(atPath: root.appendingPathComponent("envs/\(name)").path)
    }
}
