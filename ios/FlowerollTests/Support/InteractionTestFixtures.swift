import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Floweroll



final class HomePresentationPageSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [HostTaskIndexPage]
    private var index = 0

    init(_ pages: [HostTaskIndexPage]) {
        self.pages = pages
    }

    func next() -> HostTaskIndexPage {
        lock.lock()
        defer { lock.unlock() }
        guard !pages.isEmpty else {
            return HostTaskIndexPage(items: [], nextCursor: nil)
        }
        let page = pages[min(index, pages.count - 1)]
        index += 1
        return page
    }
}



final class HostTaskViewSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var views: [HostTaskView]
    private var index = 0

    init(_ views: [HostTaskView]) {
        self.views = views
    }

    func next() -> HostTaskView {
        lock.lock()
        defer { lock.unlock() }
        precondition(!views.isEmpty)
        let view = views[min(index, views.count - 1)]
        index += 1
        return view
    }
}


final class PresentationRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(method: String, path: String, query: String?)] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append((
            request.httpMethod ?? "GET",
            request.url?.path ?? "",
            request.url?.query
        ))
        lock.unlock()
    }

    func count(suffix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.path.hasSuffix(suffix) }.count
    }

    func count(method: String, path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.method == method && $0.path == path }.count
    }

    func queries(path: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.path == path }.compactMap(\.query)
    }
}


final class HomePresentationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responseHandler: ((URLRequest) throws -> (Int, Data))?
    private static let lock = NSLock()

    static func install(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock()
        responseHandler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responseHandler = nil
        lock.unlock()
    }

    private static func handler() -> ((URLRequest) throws -> (Int, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return responseHandler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler() else {
                throw URLError(.resourceUnavailable)
            }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}


func installTaskIndexBucketResponses(
    running: HostTaskIndexPage,
    needsUser: HostTaskIndexPage,
    history: HostTaskIndexPage = HostTaskIndexPage(items: [], nextCursor: nil)
) {
    let encoder = JSONEncoder.floweroll
    let runningData = try! encoder.encode(running)
    let needsUserData = try! encoder.encode(needsUser)
    let historyData = try! encoder.encode(history)
    HomePresentationURLProtocol.install { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let bucket = components.queryItems?.first(where: { $0.name == "bucket" })?.value
        switch bucket {
        case "running": return (200, runningData)
        case "needs_user": return (200, needsUserData)
        default: return (200, historyData)
        }
    }
}


func installDetailCancelResponses(
    counter: PresentationRequestCounter,
    taskID: String,
    cancelResponse: HostTaskCancellationResponse,
    terminalView: HostTaskView,
    terminalIndex: HostTaskIndexItem
) {
    let encoder = JSONEncoder.floweroll
    let cancelData = try! encoder.encode(cancelResponse)
    let viewData = try! encoder.encode(terminalView)
    let historyData = try! encoder.encode(HostTaskIndexPage(items: [terminalIndex], nextCursor: nil))
    let emptyData = try! encoder.encode(HostTaskIndexPage(items: [], nextCursor: nil))
    HomePresentationURLProtocol.install { request in
        counter.record(request)
        let path = request.url?.path ?? ""
        if request.httpMethod == "POST", path == "/v1/tasks/\(taskID)/cancel" {
            return (202, cancelData)
        }
        if request.httpMethod == "GET", path == "/v1/tasks/\(taskID)/view" {
            return (200, viewData)
        }
        if request.httpMethod == "GET", path == "/v1/tasks" {
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let bucket = components.queryItems?.first(where: { $0.name == "bucket" })?.value
            return (200, bucket == "history" ? historyData : emptyData)
        }
        return (404, Data())
    }
}


func installCancelAcceptedWithReadbackFailureResponses(
    counter: PresentationRequestCounter,
    taskID: String,
    cancelResponse: HostTaskCancellationResponse,
    terminalIndex: HostTaskIndexItem
) {
    let encoder = JSONEncoder.floweroll
    let cancelData = try! encoder.encode(cancelResponse)
    let historyData = try! encoder.encode(HostTaskIndexPage(items: [terminalIndex], nextCursor: nil))
    let emptyData = try! encoder.encode(HostTaskIndexPage(items: [], nextCursor: nil))
    HomePresentationURLProtocol.install { request in
        counter.record(request)
        let path = request.url?.path ?? ""
        if request.httpMethod == "POST", path == "/v1/tasks/\(taskID)/cancel" {
            return (202, cancelData)
        }
        if request.httpMethod == "GET", path == "/v1/tasks/\(taskID)/view" {
            return (503, Data(#"{"code":"TEMPORARY_READBACK_FAILURE"}"#.utf8))
        }
        if request.httpMethod == "GET", path == "/v1/tasks" {
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let bucket = components.queryItems?.first(where: { $0.name == "bucket" })?.value
            return (200, bucket == "history" ? historyData : emptyData)
        }
        return (404, Data())
    }
}


func installPresentationTruthResponses(
    counter: PresentationRequestCounter,
    terminalIndex: HostTaskIndexItem,
    terminalView: HostTaskView
) {
    HomePresentationURLProtocol.install { request in
        counter.record(request)
        if request.url?.path.hasSuffix("/view") == true {
            return (200, try JSONEncoder.floweroll.encode(terminalView))
        }
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        let page = query["bucket"] == "history"
            ? HostTaskIndexPage(items: [terminalIndex], nextCursor: nil)
            : HostTaskIndexPage(items: [], nextCursor: nil)
        return (200, try JSONEncoder.floweroll.encode(page))
    }
}
