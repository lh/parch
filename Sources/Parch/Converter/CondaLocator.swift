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
}
