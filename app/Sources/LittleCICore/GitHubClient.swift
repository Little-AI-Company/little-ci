import Foundation

/// Reads and writes GitHub's REST API. The token comes from the `gh` login and stays in memory.
public actor GitHubClient {
    public enum ClientError: Error, Equatable, CustomStringConvertible {
        case noToken(String)
        case http(status: Int, path: String, message: String)

        public var description: String {
            switch self {
            case .noToken(let reason): "No GitHub token from the gh login: \(reason)"
            case .http(let status, let path, let message): "GitHub returned \(status) for \(path): \(message)"
            }
        }
    }

    private let commandRunner: any CommandRunning
    private let session: URLSession
    private var token: String?
    public private(set) var rateLimitRemaining: Int?

    // Values that change slowly are cached for a few minutes.
    private var pullRequestCache: (byBranch: [String: PullRequestState], fetchedAt: Date)?
    private var toolchainCache: (value: ToolchainRequirement?, fetchedAt: Date)?
    private var redMainCache: (runID: Int, jobs: [String])?

    public init(commandRunner: any CommandRunning = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
        self.session = URLSession(configuration: .ephemeral, delegate: RedirectWithoutCredentials(), delegateQueue: nil)
    }

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Snapshot

    public func snapshot(for inventory: Inventory, now: Date = Date()) async throws -> GitHubSnapshot {
        let target = inventory.github
        let runners = try await allRunners(target)
        var activeRuns: [WorkflowRun] = []
        for status in ["queued", "in_progress", "waiting", "pending"] {
            activeRuns += try await runs(target, query: "status=\(status)&per_page=100")
        }
        activeRuns = Array(Dictionary(activeRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.createdAt < $1.createdAt }

        var activeJobs: [WorkflowJob] = []
        for run in activeRuns where run.status == "in_progress" {
            activeJobs += try await jobs(target, runID: run.id, filter: "latest")
        }

        let recentMainRuns = try await runs(target, query: "branch=main&status=completed&per_page=50")
            .filter { $0.name == inventory.queue.checkWorkflow && ["success", "failure"].contains($0.conclusion) }
        let redMainJobs = try await failedJobNames(of: recentMainRuns.first, target: target)
        return GitHubSnapshot(observedAt: now, runners: runners, activeRuns: activeRuns, activeJobs: activeJobs,
                              recentMainRuns: recentMainRuns, redMainJobs: redMainJobs,
                              pullRequests: try await pullRequestsByBranch(target, now: now),
                              toolchain: try await toolchain(target, now: now))
    }

    public func allRunners(_ target: GitHubTarget) async throws -> [GitHubRunner] {
        struct Page: Decodable { var totalCount: Int; var runners: [GitHubRunner] }
        var all: [GitHubRunner] = []
        for page in 1... {
            let body: Page = try await get("\(target.runnersPath)?per_page=100&page=\(page)")
            all += body.runners
            if body.runners.count < 100 || all.count >= body.totalCount { return all }
        }
        return all
    }

    public func runs(_ target: GitHubTarget, query: String) async throws -> [WorkflowRun] {
        struct Page: Decodable { var workflowRuns: [WorkflowRun] }
        let body: Page = try await get("\(target.repositoryPath)/actions/runs?\(query)")
        return body.workflowRuns
    }

    public func run(_ target: GitHubTarget, id: Int) async throws -> WorkflowRun {
        try await get("\(target.repositoryPath)/actions/runs/\(id)")
    }

    public func jobs(_ target: GitHubTarget, runID: Int, filter: String) async throws -> [WorkflowJob] {
        struct Page: Decodable { var totalCount: Int; var jobs: [WorkflowJob] }
        var all: [WorkflowJob] = []
        for page in 1... {
            let body: Page = try await get("\(target.repositoryPath)/actions/runs/\(runID)/jobs?filter=\(filter)&per_page=100&page=\(page)")
            all += body.jobs
            if body.jobs.count < 100 || all.count >= body.totalCount { return all }
        }
        return all
    }

    /// A job's check-run annotations. Some failures (a full disk that stops the log) appear only here.
    public func jobAnnotations(_ target: GitHubTarget, jobID: Int) async throws -> [String] {
        struct Annotation: Decodable { var message: String }
        let annotations: [Annotation] = try await get("\(target.repositoryPath)/check-runs/\(jobID)/annotations?per_page=50")
        return annotations.map(\.message)
    }

    public func jobLog(_ target: GitHubTarget, jobID: Int) async throws -> String {
        String(decoding: try await request("GET", "\(target.repositoryPath)/actions/jobs/\(jobID)/logs"), as: UTF8.self)
    }

    private func failedJobNames(of run: WorkflowRun?, target: GitHubTarget) async throws -> [String] {
        guard let run, run.conclusion == "failure" else { return [] }
        if let redMainCache, redMainCache.runID == run.id { return redMainCache.jobs }
        let names = try await jobs(target, runID: run.id, filter: "latest")
            .filter { $0.conclusion == "failure" && $0.name != "Check" }.map(\.name).sorted()
        redMainCache = (run.id, names)
        return names
    }

    /// Recently updated pull requests by head branch. Runs carry `pull_requests` for only some PR runs
    /// (99 of 317 on 2026-10-20), so the branch is the reliable link.
    private func pullRequestsByBranch(_ target: GitHubTarget, now: Date) async throws -> [String: PullRequestState] {
        if let cached = pullRequestCache, now.timeIntervalSince(cached.fetchedAt) < 300 { return cached.byBranch }
        struct Pull: Decodable {
            struct Head: Decodable { var ref: String }
            var number: Int
            var state: String
            var mergedAt: Date?
            var head: Head
        }
        var byBranch: [String: PullRequestState] = [:]
        for page in 1...3 {
            let pulls: [Pull] = try await get("\(target.repositoryPath)/pulls?state=all&sort=updated&direction=desc&per_page=100&page=\(page)")
            for pull in pulls {
                let state = PullRequestState(number: pull.number, state: pull.state, merged: pull.mergedAt != nil, headBranch: pull.head.ref)
                if byBranch[pull.head.ref]?.isOpen != true { byBranch[pull.head.ref] = state }
            }
            if pulls.count < 100 { break }
        }
        pullRequestCache = (byBranch, now)
        return byBranch
    }

    /// Bun from package.json's packageManager, Node from engines.node, on the default branch.
    private func toolchain(_ target: GitHubTarget, now: Date) async throws -> ToolchainRequirement? {
        if let toolchainCache, now.timeIntervalSince(toolchainCache.fetchedAt) < 600 { return toolchainCache.value }
        struct Contents: Decodable { var content: String }
        struct PackageJSON: Decodable {
            struct Engines: Decodable { var node: String? }
            var packageManager: String?
            var engines: Engines?
        }
        let value: ToolchainRequirement?
        do {
            let contents: Contents = try await get("\(target.repositoryPath)/contents/package.json")
            let decoded = Data(base64Encoded: contents.content, options: .ignoreUnknownCharacters) ?? Data()
            let package = try JSONDecoder().decode(PackageJSON.self, from: decoded)
            value = ToolchainRequirement(
                bunVersion: package.packageManager?.firstMatch(of: /^bun@(.+)$/).map { String($0.1) },
                minimumNodeMajor: package.engines?.node?.firstMatch(of: />=\s*(\d+)/).flatMap { Int($0.1) })
        } catch ClientError.http(status: 404, _, _) {
            value = nil
        }
        toolchainCache = (value, now)
        return value
    }

    // MARK: Writes (only through confirmed plans)

    public func cancelRun(_ target: GitHubTarget, id: Int) async throws {
        _ = try await request("POST", "\(target.repositoryPath)/actions/runs/\(id)/cancel")
    }

    public func registrationToken(_ target: GitHubTarget) async throws -> String {
        struct Token: Decodable { var token: String }
        let body: Token = try Self.decoder.decode(Token.self, from: try await request("POST", "\(target.runnersPath)/registration-token"))
        return body.token
    }

    public func removalToken(_ target: GitHubTarget) async throws -> String {
        struct Token: Decodable { var token: String }
        let body: Token = try Self.decoder.decode(Token.self, from: try await request("POST", "\(target.runnersPath)/remove-token"))
        return body.token
    }

    // MARK: Transport

    func get<Value: Decodable>(_ path: String) async throws -> Value {
        try Self.decoder.decode(Value.self, from: try await request("GET", path))
    }

    func request(_ method: String, _ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(try await currentToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 60
        let (body, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if let remaining = http?.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init) { rateLimitRemaining = remaining }
        let status = http?.statusCode ?? 0
        if status == 401 { token = nil }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: body))?["message"]
                ?? String(decoding: body.prefix(200), as: UTF8.self)
            throw ClientError.http(status: status, path: path, message: message)
        }
        return body
    }

    private func currentToken() async throws -> String {
        if let token { return token }
        guard let gh = Self.ghExecutable else { throw ClientError.noToken("gh is not installed in /opt/homebrew/bin or /usr/local/bin") }
        let result = try await commandRunner.run(CommandInvocation(gh, ["auth", "token"]), standardInput: nil, timeout: .seconds(15))
        let value = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !value.isEmpty else { throw ClientError.noToken(result.errorText) }
        token = value
        return value
    }

    static var ghExecutable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Job logs redirect to blob storage. Forwarding GitHub's token there is a leak and is rejected (401).
final class RedirectWithoutCredentials: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var redirected = request
        if request.url?.host != task.originalRequest?.url?.host {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return redirected
    }
}
