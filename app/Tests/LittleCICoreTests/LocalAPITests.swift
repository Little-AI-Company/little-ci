import Foundation
import Testing
@testable import LittleCICore

@Suite("Local API")
struct LocalAPITests {
    func state() -> FleetState {
        let probe = ProbeFixture("m1-macos").replacing("orbstack_vmgr", with: Fixture.text("sections/orbstack-vmgr-mount-failure.txt"))
        let observations = FleetObservations(inventory: Fixture.inventory, github: Fixture.snapshot(online: Fixture.m1CheckRunners),
                                             hosts: ["m1": probe.observation(for: "m1"),
                                                     "m4": HostObservation(hostID: "m4", attemptedAt: Fixture.now, outcome: .unreachable("ssh: timeout"))],
                                             lentHosts: ["m1"])
        let assessment = Assessor.assess(observations, now: Fixture.now)
        let events = EventJournal.transitions(from: nil, to: assessment)
        return FleetState(source: .live, observations: observations, assessment: assessment, events: events, lastOutcome: nil,
                          settings: AppSettings())
    }

    func get(_ target: String, headers: [String: String] = ["Host": "127.0.0.1:47623"], method: String = "GET") -> APIResponse {
        APIRouter.respond(method: method, target: target, headers: headers, state: state(), port: 47623)
    }

    @Test("Browser pages, other hosts and writes are rejected")
    func requestBoundary() {
        #expect(get("/v1/summary", headers: ["Host": "127.0.0.1:47623", "Origin": "https://example.com"]).status == 403)
        #expect(get("/v1/summary", headers: ["Host": "evil.example:47623"]).status == 403)
        #expect(get("/v1/summary", method: "POST").status == 405)
        #expect(get("/v1/summary", method: "DELETE").status == 405)
        #expect(get("/v1/events?limit=0").status == 400)
        #expect(get("/v1/nothing").status == 404)
    }

    @Test("Every route's real response matches the OpenAPI schema generated from the models")
    func responsesMatchSchema() throws {
        let document = APIRouter.openAPI()
        guard case .object(let root) = document, case .object(let paths)? = root["paths"],
              case .object(let components)? = root["components"], case .object(let schemas)? = components["schemas"] else {
            Issue.record("OpenAPI document has no paths or schemas")
            return
        }
        let validator = SchemaValidator(schemas: schemas)
        for (path, item) in paths {
            guard case .object(let operations) = item, case .object(let operation)? = operations["get"],
                  case .object(let responses)? = operation["responses"], case .object(let ok)? = responses["200"],
                  case .object(let content)? = ok["content"], case .object(let json)? = content["application/json"],
                  let schema = json["schema"] else {
                Issue.record("\(path) has no response schema")
                continue
            }
            let response = get(path)
            #expect(response.status == 200, "\(path)")
            let value = try JSONDecoder().decode(JSONValue.self, from: response.body)
            let problems = validator.problems(value, schema, at: path)
            #expect(problems.isEmpty, "\(problems.prefix(5))")
        }
    }

    @Test("Responses never contain a token")
    func noSecrets() {
        for path in ["/v1/hosts", "/v1/runners", "/v1/plans", "/v1/findings", "/v1/events"] {
            let body = String(decoding: get(path).body, as: UTF8.self)
            #expect(!body.contains("ghp_") && !body.contains("gho_") && !body.contains("github_pat_"), "\(path)")
        }
    }
}

/// Enough of JSON Schema to check that every encoded key is declared and every required key is present.
struct SchemaValidator {
    let schemas: [String: JSONValue]

    func problems(_ value: JSONValue, _ schema: JSONValue, at path: String) -> [String] {
        guard case .object(let rule) = schema else { return [] }
        if case .string(let reference)? = rule["$ref"] {
            let name = String(reference.split(separator: "/").last ?? "")
            guard let target = schemas[name] else { return ["\(path): unknown \(reference)"] }
            return problems(value, target, at: path)
        }
        if case .array(let choices)? = rule["oneOf"] {
            let results = choices.map { problems(value, $0, at: path) }
            if results.contains(where: \.isEmpty) { return [] }
            return ["\(path): matches no oneOf branch; closest: \(results.min { $0.count < $1.count } ?? [])"]
        }
        if case .array(let parts)? = rule["allOf"] {
            // allOf here is a payload plus its `type` tag: check the union of their properties.
            var merged: [String: JSONValue] = [:]
            for case .object(let part) in parts.map(resolve) {
                if case .object(let properties)? = part["properties"] { merged.merge(properties) { first, _ in first } }
            }
            return problems(value, .object(["type": .string("object"), "properties": .object(merged)]), at: path)
        }
        switch (rule["type"], value) {
        case (.string("object")?, .object(let object)):
            var found: [String] = []
            if case .object(let properties)? = rule["properties"] {
                if case .array(let required)? = rule["required"] {
                    for case .string(let key) in required where object[key] == nil { found.append("\(path): missing \(key)") }
                }
                if rule["additionalProperties"] == nil || rule["additionalProperties"] == .bool(false) {
                    for (key, child) in object {
                        guard let childSchema = properties[key] else { found.append("\(path): undeclared key \(key)"); continue }
                        found += problems(child, childSchema, at: "\(path).\(key)")
                    }
                }
            }
            if let values = rule["additionalProperties"], case .object = values {
                for (key, child) in object { found += problems(child, values, at: "\(path).\(key)") }
            }
            return found
        case (.string("array")?, .array(let items)):
            guard let itemSchema = rule["items"] else { return [] }
            return items.enumerated().flatMap { problems($1, itemSchema, at: "\(path)[\($0)]") }
        case (.string("string")?, .string(let text)):
            if case .array(let allowed)? = rule["enum"], !allowed.contains(.string(text)) { return ["\(path): \(text) not in enum"] }
            return []
        case (.string("integer")?, .number), (.string("number")?, .number), (.string("boolean")?, .bool), (nil, _):
            return []
        default:
            return ["\(path): \(value) does not match \(rule["type"] ?? .null)"]
        }
    }

    func resolve(_ schema: JSONValue) -> JSONValue {
        if case .object(let rule) = schema, case .string(let reference)? = rule["$ref"] {
            return schemas[String(reference.split(separator: "/").last ?? "")] ?? schema
        }
        return schema
    }
}
