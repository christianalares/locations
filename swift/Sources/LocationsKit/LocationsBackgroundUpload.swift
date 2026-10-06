#if os(iOS)
import Foundation

/// File-backed transfers survive ordinary suspension and process termination.
/// The phone ledger remains the retry queue until the server acknowledges it.
@MainActor
final class LocationsBackgroundUpload: NSObject, URLSessionDataDelegate {
    static let shared = LocationsBackgroundUpload()
    static let identifier = "se.hiddenvillage.locations.timeline-upload"

    var recoveredUpload: ((Data) -> Void)?
    var recoveredFailure: ((Error) -> Void)?
    private var completion: (() -> Void)?
    private var responses: [Int: Data] = [:]
    private var continuations: [Int: CheckedContinuation<Data, Error>] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 3_600
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    private var directory: URL {
        BlipTimelinePersistence.applicationSupport().fileURL!.deletingLastPathComponent()
            .appendingPathComponent("Uploads", isDirectory: true)
    }

    func reconnect() {
        _ = session
    }

    func handleEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.identifier else {
            completion()
            return
        }

        self.completion = completion
        reconnect()
    }

    func cancelUploads() {
        session.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
    }

    func upload(request: URLRequest, body: Data) async throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(UUID().uuidString).json.gz")
        try body.locationsGzipped().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = file.lastPathComponent
        task.priority = URLSessionTask.highPriority

        return try await withCheckedThrowingContinuation { continuation in
            continuations[task.taskIdentifier] = continuation
            task.resume()
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            responses[dataTask.taskIdentifier, default: Data()].append(data)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            let data = responses.removeValue(forKey: task.taskIdentifier) ?? Data()
            let continuation = continuations.removeValue(forKey: task.taskIdentifier)
            let file = task.taskDescription.map { directory.appendingPathComponent($0) }
            defer {
                if let file {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                if continuation == nil {
                    recoveredFailure?(error)
                }
                continuation?.resume(throwing: error)
            } else if !(200..<300).contains(status) {
                let error = status == 401 || status == 403
                    ? LocationsSyncError.unauthorized : LocationsSyncError.server(status)
                if continuation == nil {
                    recoveredFailure?(error)
                }
                continuation?.resume(throwing: error)
            } else {
                if continuation == nil,
                   (try? JSONSerialization.jsonObject(with: data) as? [String: Bool])?["accepted"] == true,
                   let file, let compressed = try? Data(contentsOf: file),
                   let body = try? compressed.locationsGunzip() {
                    recoveredUpload?(body)
                }
                continuation?.resume(returning: data)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            let handler = completion
            completion = nil
            handler?()
        }
    }
}
#endif
