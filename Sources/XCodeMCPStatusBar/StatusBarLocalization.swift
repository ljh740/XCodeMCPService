import Foundation

enum StatusBarLocalization {
    private static let bundleName = "XCodeMCPService_XCodeMCPStatusBar.bundle"

    static let bundle: Bundle = {
        let candidates = candidateURLs()

        for url in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        let searchedPaths = candidates.map(\.path).joined(separator: " or ")
        Swift.fatalError("could not load resource bundle: searched \(searchedPaths)")
    }()

    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(bundleName, isDirectory: true))
        }

        urls.append(Bundle.main.bundleURL.appendingPathComponent(bundleName, isDirectory: true))

        if let executableURL = Bundle.main.executableURL {
            let executableDirectory = executableURL.deletingLastPathComponent()
            urls.append(executableDirectory.appendingPathComponent(bundleName, isDirectory: true))
        }

        var seenPaths = Set<String>()
        return urls.filter { seenPaths.insert($0.path).inserted }
    }
}
