import Foundation

class EnvLoader {
    static let shared = EnvLoader()
    private var envVariables: [String: String] = [:]

    private init() {
        loadEnvFile()
    }

    private func loadEnvFile() {
        // Try to find .env file in project directory
        let possiblePaths = [
            // Running from Xcode - current directory
            FileManager.default.currentDirectoryPath + "/.env",
            // Project root (when running from Xcode)
            "/Users/aymeric/Documents/Code/Stakhanova/.env",
            // Running from app bundle
            Bundle.main.bundlePath + "/../../../../../../.env",
            // Relative to bundle
            (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/.env"
        ]

        print("EnvLoader: Searching for .env file...")
        print("EnvLoader: Current directory: \(FileManager.default.currentDirectoryPath)")
        print("EnvLoader: Bundle path: \(Bundle.main.bundlePath)")

        for path in possiblePaths {
            print("EnvLoader: Checking path: \(path)")
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                parseEnvFile(contents)
                print("EnvLoader: Successfully loaded .env from: \(path)")
                print("EnvLoader: Loaded \(envVariables.count) variables: \(Array(envVariables.keys))")
                return
            }
        }

        print("EnvLoader: Warning - .env file not found in any of the checked paths")
    }

    private func parseEnvFile(_ contents: String) {
        let lines = contents.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            // Parse KEY=VALUE or KEY="VALUE"
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)

                // Remove quotes if present
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }

                envVariables[key] = value
            }
        }
    }

    func get(_ key: String) -> String? {
        return envVariables[key]
    }
}
