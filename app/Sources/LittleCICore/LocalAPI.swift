import Foundation
import Network

public struct APISummary: Codable, Sendable, Equatable {
    public var worstSeverity: Severity?
    public var findings: [String: Int]
    public var hosts: Int
    public var hostsReachable: Int
    public var runnersOnline: Int
    public var runnersBusy: Int
    public var activeRuns: Int
    public var githubObservedAt: Date?
    public var serviceLevels: [ServiceLevel]
}

public struct APIHost: Codable, Sendable, Equatable {
    public var spec: HostSpec
    public var lent: Bool
    public var observation: HostObservation?
}

public struct APIRunner: Codable, Sendable, Equatable {
    public var name: String
    public var hostID: String?
    public var github: GitHubRunner?
    public var service: RunnerServiceFacts?
}

public struct APIEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public var apiVersion: Int
    public var source: DataSource
    public var generatedAt: Date
    public var data: Payload
}

public struct APIResponse: Sendable, Equatable {
    public var status: Int
    public var contentType = "application/json"
    public var body: Data
}

/// Routes for scripts and agents on this Mac. Read-only: no route changes a host, a runner or GitHub.
public enum APIRouter {
    public static let version = 1
    public static let defaultPort: UInt16 = 47623

    struct Route {
        var path: String
        var summary: String
        var payload: any Decodable.Type
    }

    static var routes: [Route] { [
        Route(path: "/v1/summary", summary: "Counts, worst severity and service levels", payload: APISummary.self),
        Route(path: "/v1/hosts", summary: "Inventory hosts with their latest observation", payload: [APIHost].self),
        Route(path: "/v1/runners", summary: "Declared and GitHub runners with GitHub and service state", payload: [APIRunner].self),
        Route(path: "/v1/queue", summary: "Active runs by lane, with superseded, closed-PR and red-main marks", payload: [QueueEntry].self),
        Route(path: "/v1/findings", summary: "Current findings, worst first", payload: [Finding].self),
        Route(path: "/v1/plans", summary: "Plans the app offers (they run only from the app, after review)", payload: [Plan].self),
        Route(path: "/v1/events", summary: "Observed transitions, newest first; ?limit=1..200 (default 50)", payload: [FleetEvent].self),
        Route(path: "/v1/service-levels", summary: "Service levels against their targets", payload: [ServiceLevel].self),
    ] }

    public static func respond(method: String, target: String, headers: [String: String], state: FleetState?, port: UInt16) -> APIResponse {
        let names = headers.keys.map { $0.lowercased() }
        guard Set(names).count == names.count else { return error(400, "invalid_request", "A header appears twice.") }
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        if lowered["origin"] != nil { return error(403, "forbidden", "Requests with an Origin header are rejected.") }
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard let host = lowered["host"], allowedHosts.contains(host) else { return error(403, "forbidden", "The Host header must be loopback.") }
        guard method == "GET" || method == "HEAD" else { return error(405, "method_not_allowed", "Only GET and HEAD are accepted.") }

        let components = URLComponents(string: "http://localhost\(target)")
        let path = components?.path ?? target
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let response: APIResponse
        switch path {
        case "/": response = encode(index())
        case "/v1/openapi.json": response = encode(openAPI())
        default:
            guard let state else { return error(503, "not_ready", "The first observation has not finished.") }
            switch path {
            case "/v1/summary": response = envelope(summary(state), state)
            case "/v1/hosts": response = envelope(hosts(state), state)
            case "/v1/runners": response = envelope(runners(state), state)
            case "/v1/queue": response = envelope(state.assessment.queue, state)
            case "/v1/findings": response = envelope(state.assessment.findings, state)
            case "/v1/plans": response = envelope(state.assessment.plans, state)
            case "/v1/service-levels": response = envelope(state.assessment.serviceLevels, state)
            case "/v1/events":
                guard let limit = Int(query["limit"] ?? "50"), (1...200).contains(limit) else {
                    return error(400, "invalid_request", "limit must be 1 to 200")
                }
                response = envelope(Array(state.events.prefix(limit)), state)
            default: return error(404, "not_found", "No route \(path). GET / lists the routes.")
            }
        }
        return method == "HEAD" ? APIResponse(status: response.status, body: Data()) : response
    }

    // MARK: Views

    static func summary(_ state: FleetState) -> APISummary {
        let assessment = state.assessment
        let github = state.observations.github
        let fleet = github.map(state.observations.inventory.declaredRunners(in:)) ?? []
        return APISummary(
            worstSeverity: assessment.worstSeverity,
            findings: Dictionary(grouping: assessment.findings, by: { "\($0.severity)" }).mapValues(\.count),
            hosts: state.observations.inventory.hosts.count,
            hostsReachable: state.observations.hosts.values.filter { $0.facts != nil }.count,
            runnersOnline: fleet.filter { $0.status == .online }.count,
            runnersBusy: fleet.filter(\.busy).count,
            activeRuns: github?.activeRuns.count ?? 0,
            githubObservedAt: github?.observedAt,
            serviceLevels: assessment.serviceLevels)
    }

    static func hosts(_ state: FleetState) -> [APIHost] {
        state.observations.inventory.hosts.map {
            APIHost(spec: $0, lent: state.settings.lentHosts.contains($0.id), observation: state.observations.hosts[$0.id])
        }
    }

    static func runners(_ state: FleetState) -> [APIRunner] {
        let inventory = state.observations.inventory
        let github = state.observations.github?.runners ?? []
        let declared = inventory.hosts.flatMap { host in host.runners.map { (host, $0.name) } }
        var views = declared.map { host, name in
            APIRunner(name: name, hostID: host.id, github: github.first { $0.name == name },
                      service: state.observations.hosts[host.id]?.facts?.runner(named: name))
        }
        views += github.filter { runner in !declared.contains { $0.1 == runner.name } }
            .map { APIRunner(name: $0.name, hostID: nil, github: $0, service: nil) }
        return views.sorted { $0.name < $1.name }
    }

    // MARK: Documents

    static func index() -> JSONValue {
        .object([
            "apiVersion": .number(Double(version)),
            "routes": .array((routes.map(\.path) + ["/v1/openapi.json"]).map(JSONValue.string)),
            "rules": .array([
                "Read-only. Plans run only from the app, after review.",
                "Loopback clients only; requests with an Origin header are rejected.",
                "Missing or stale data is not zero, idle or healthy: check observedAt and attemptedAt.",
                "source: demo marks fictional observations.",
            ].map(JSONValue.string)),
        ])
    }

    public static func openAPI() -> JSONValue {
        let generator = SchemaGenerator()
        var paths: [String: JSONValue] = [:]
        for route in routes {
            let envelope = JSONValue.properties([
                "apiVersion": generator.schema(for: Int.self), "source": generator.schema(for: DataSource.self),
                "generatedAt": generator.schema(for: Date.self), "data": generator.schema(for: route.payload),
            ])
            paths[route.path] = .object(["get": .object([
                "summary": .string(route.summary),
                "responses": .object(["200": .object(["description": .string("OK"),
                                                      "content": .object(["application/json": .object(["schema": envelope])])])]),
            ])])
        }
        return .object([
            "openapi": .string("3.1.0"),
            "info": .object(["title": .string("Little CI local API"), "version": .string(String(version))]),
            "servers": .array([.object(["url": .string("http://127.0.0.1:\(defaultPort)")])]),
            "paths": .object(paths),
            "components": .object(["schemas": .object(generator.components)]),
        ])
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func encode<Value: Encodable>(_ value: Value, status: Int = 200) -> APIResponse {
        APIResponse(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    static func envelope<Payload: Codable & Sendable>(_ payload: Payload, _ state: FleetState) -> APIResponse {
        encode(APIEnvelope(apiVersion: version, source: state.source, generatedAt: state.assessment.assessedAt, data: payload))
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> APIResponse {
        encode(["code": code, "error": message], status: status)
    }
}

/// Serves `APIRouter` on 127.0.0.1. One request per connection.
public final class LocalAPIServer: @unchecked Sendable {
    private let listener: NWListener
    private let port: UInt16
    private let queue = DispatchQueue(label: "LittleCI.LocalAPI")
    private let currentState: @Sendable () async -> FleetState?

    public init(port: UInt16 = APIRouter.defaultPort, state: @escaping @Sendable () async -> FleetState?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        self.port = port
        currentState = state
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint, ["127.0.0.1", "::1"].contains("\(host)") else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        // A client that does not finish its request in 10 s is dropped.
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(connection, header: buffer[..<headerEnd.lowerBound])
            } else if complete || error != nil || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ connection: NWConnection, header: Data) {
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        var headers: [String: String] = [:]
        var duplicate = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            if headers.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { duplicate = true }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let port = self.port
        let currentState = self.currentState
        Task {
            let response = duplicate ? APIRouter.error(400, "invalid_request", "A header appears twice.")
                : requestLine.count == 3
                ? APIRouter.respond(method: requestLine[0], target: requestLine[1], headers: headers, state: await currentState(), port: port)
                : APIRouter.error(400, "invalid_request", "Malformed request line")
            let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][response.status] ?? "Error"
            var head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\n"
            head += "Content-Length: \(response.body.count)\r\nX-Api-Version: \(APIRouter.version)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
