import Foundation

/// A JSON value, for schemas and the API's index document.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
}

/// String enums list their values in the schema.
public protocol SchemaEnum: CaseIterable, RawRepresentable, Decodable where RawValue == String {}

/// Types whose Codable form is hand-written (enums with payloads, single-value types) state their schema here.
public protocol SchemaDescribed: Decodable {
    static func jsonSchema(_ generator: SchemaGenerator) -> JSONValue
    static var schemaExample: Self { get }
}

protocol SchemaDictionary { static var valueType: any Decodable.Type { get } }
extension Dictionary: SchemaDictionary where Key == String, Value: Decodable {
    static var valueType: any Decodable.Type { Value.self }
}

/// Builds JSON Schemas by decoding each model with a decoder that records what it asks for: every key,
/// whether it is required (`decode`) or optional (`decodeIfPresent`), and each value's type.
public final class SchemaGenerator {
    public private(set) var components: [String: JSONValue] = [:]

    public init() {}

    public func schema(for type: any Decodable.Type) -> JSONValue {
        switch type {
        case is String.Type: return .object(["type": .string("string")])
        case is Int.Type, is Int64.Type, is Int32.Type: return .object(["type": .string("integer")])
        case is Double.Type: return .object(["type": .string("number")])
        case is Bool.Type: return .object(["type": .string("boolean")])
        case is Date.Type: return .object(["type": .string("string"), "format": .string("date-time")])
        case is UUID.Type: return .object(["type": .string("string"), "format": .string("uuid")])
        default: break
        }
        if let enumType = type as? any SchemaEnum.Type { return enumSchema(enumType) }
        if let dictionary = type as? any SchemaDictionary.Type {
            return .object(["type": .string("object"), "additionalProperties": schema(for: dictionary.valueType)])
        }
        let name = Self.name(of: type)
        if components[name] == nil {
            components[name] = .object([:])  // placeholder while the type is being recorded
            if let described = type as? any SchemaDescribed.Type {
                components[name] = described.jsonSchema(self)
            } else {
                let node = Node()
                _ = try? type.init(from: RecordingDecoder(generator: self, node: node))
                components[name] = node.schema
            }
        }
        return .object(["$ref": .string("#/components/schemas/\(name)")])
    }

    /// An instance to hand back to the model's initializer while recording.
    func example<Value: Decodable>(_ type: Value.Type) throws -> Value {
        _ = schema(for: type)
        let primitives: [Any] = ["", 0, Int64(0), Int32(0), 0.0, false, Date(timeIntervalSince1970: 0), UUID()]
        if let primitive = primitives.first(where: { Swift.type(of: $0) == type }) { return primitive as! Value }
        if let described = type as? any SchemaDescribed.Type { return described.schemaExample as! Value }
        if let enumType = type as? any SchemaEnum.Type { return firstCase(enumType) as! Value }
        return try Value(from: RecordingDecoder(generator: self, node: Node()))
    }

    private func enumSchema<E: SchemaEnum>(_ type: E.Type) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(type.allCases.map { .string($0.rawValue) })])
    }

    private func firstCase<E: SchemaEnum>(_ type: E.Type) -> E { type.allCases.first! }

    static func name(of type: Any.Type) -> String {
        String(reflecting: type).split(separator: ".").dropFirst().joined(separator: "_")
    }

    final class Node {
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        var items: JSONValue?
        var single: JSONValue?

        var schema: JSONValue {
            if let single { return single }
            if let items { return .object(["type": .string("array"), "items": items]) }
            var object: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
            if !required.isEmpty { object["required"] = .array(required.sorted().map(JSONValue.string)) }
            return .object(object)
        }
    }
}

private struct RecordingDecoder: Decoder {
    let generator: SchemaGenerator
    let node: SchemaGenerator.Node
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(KeyedRecorder<Key>(generator: generator, node: node))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer { UnkeyedRecorder(generator: generator, node: node) }
    func singleValueContainer() throws -> any SingleValueDecodingContainer { SingleRecorder(generator: generator, node: node) }
}

private struct KeyedRecorder<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let generator: SchemaGenerator
    let node: SchemaGenerator.Node
    var codingPath: [any CodingKey] = []
    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        node.properties[key.stringValue] = generator.schema(for: type)
        if !node.required.contains(key.stringValue) { node.required.append(key.stringValue) }
        return try generator.example(type)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        node.properties[key.stringValue] = generator.schema(for: type)
        return nil
    }

    // The protocol's default versions of these call `decode`, which would mark the key required.
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try optional(type, key) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try optional(type, key) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try optional(type, key) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try optional(type, key) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try optional(type, key) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try optional(type, key) }

    private func optional<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        node.properties[key.stringValue] = generator.schema(for: type)
        return nil
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(KeyedRecorder<NestedKey>(generator: generator, node: SchemaGenerator.Node()))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        UnkeyedRecorder(generator: generator, node: SchemaGenerator.Node())
    }

    func superDecoder() throws -> any Decoder { RecordingDecoder(generator: generator, node: node) }
    func superDecoder(forKey key: Key) throws -> any Decoder { RecordingDecoder(generator: generator, node: node) }
}

private struct UnkeyedRecorder: UnkeyedDecodingContainer {
    let generator: SchemaGenerator
    let node: SchemaGenerator.Node
    var codingPath: [any CodingKey] = []
    var count: Int? { 1 }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex > 0 }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        currentIndex += 1
        node.items = generator.schema(for: type)
        return try generator.example(type)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        currentIndex += 1
        return KeyedDecodingContainer(KeyedRecorder<NestedKey>(generator: generator, node: SchemaGenerator.Node()))
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        currentIndex += 1
        return UnkeyedRecorder(generator: generator, node: SchemaGenerator.Node())
    }

    mutating func superDecoder() throws -> any Decoder { RecordingDecoder(generator: generator, node: node) }
}

private struct SingleRecorder: SingleValueDecodingContainer {
    let generator: SchemaGenerator
    let node: SchemaGenerator.Node
    var codingPath: [any CodingKey] = []

    func decodeNil() -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        node.single = generator.schema(for: type)
        return try generator.example(type)
    }
}

// MARK: Schemas for hand-written Codable forms

extension JSONValue {
    static func oneOf(_ choices: [JSONValue]) -> JSONValue { .object(["oneOf": .array(choices)]) }

    /// `{"<case>": { ...payload }}`, the form Swift synthesizes for enums with associated values.
    static func tagged(_ cases: [String: JSONValue]) -> JSONValue {
        .oneOf(cases.sorted { $0.key < $1.key }.map { name, payload in
            .object(["type": .string("object"), "required": .array([.string(name)]),
                     "properties": .object([name: payload]), "additionalProperties": .bool(false)])
        })
    }

    static func properties(_ properties: [String: JSONValue], required: [String]? = nil) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array((required ?? properties.keys.sorted()).map(JSONValue.string))])
    }
}

extension Severity: SchemaEnum {}
extension GitHubTarget.Scope: SchemaEnum {}
extension GitHubRunner.Status: SchemaEnum {}
extension TokenKind: SchemaEnum {}
extension FleetEvent.Kind: SchemaEnum {}
extension QueueLane: SchemaEnum {}
extension QueueEntry.Disposition: SchemaEnum {}
extension FailureClass.Cause: SchemaEnum {}
extension DataSource: SchemaEnum {}

extension HostAccess: SchemaDescribed {
    public static func jsonSchema(_ generator: SchemaGenerator) -> JSONValue {
        .object(["type": .string("string"), "pattern": .string("^(local|ssh:[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?)$")])
    }
    public static var schemaExample: HostAccess { .local }
}

extension HostKind: SchemaDescribed {
    public static func jsonSchema(_ generator: SchemaGenerator) -> JSONValue {
        let mac = generator.schema(for: MacLaunchdHost.self), vm = generator.schema(for: OrbStackVMHost.self)
        let server = generator.schema(for: LinuxServerHost.self)
        func typed(_ name: String, _ payload: JSONValue) -> JSONValue {
            .object(["allOf": .array([payload, .properties(["type": .object(["const": .string(name)])])])])
        }
        return .oneOf([typed("macLaunchd", mac), typed("orbstackVM", vm), typed("linuxServer", server)])
    }
    public static var schemaExample: HostKind { .macLaunchd(MacLaunchdHost(user: "", runnerRoot: "", serviceLabelPrefix: "")) }
}

extension Subject: SchemaDescribed {
    public static func jsonSchema(_ generator: SchemaGenerator) -> JSONValue {
        .tagged(["fleet": .properties([:]), "host": .properties(["_0": generator.schema(for: String.self)]),
                 "runner": .properties(["_0": generator.schema(for: String.self)]), "run": .properties(["_0": generator.schema(for: Int.self)])])
    }
    public static var schemaExample: Subject { .fleet }
}

extension RunnerServiceFacts.ServiceState: SchemaDescribed {
    public static func jsonSchema(_ generator: SchemaGenerator) -> JSONValue {
        let int = generator.schema(for: Int.self)
        return .tagged(["running": .properties(["pid": int]), "loadedNotRunning": .properties(["lastExitCode": int], required: []),
                        "notLoaded": .properties([:]), "unknown": .properties(["_0": generator.schema(for: String.self)])])
    }
    public static var schemaExample: RunnerServiceFacts.ServiceState { .notLoaded }
}

extension HostObservation.Outcome: SchemaDescribed {
    public static func jsonSchema(_ generator: SchemaGenerator) -> JSONValue {
        .tagged(["reached": .properties(["_0": generator.schema(for: HostFacts.self)]),
                 "unreachable": .properties(["_0": generator.schema(for: String.self)])])
    }
    public static var schemaExample: HostObservation.Outcome { .unreachable("") }
}

extension PlanAction: SchemaDescribed {
    public static func jsonSchema(_ generator: SchemaGenerator) -> JSONValue {
        let string = generator.schema(for: String.self), int = generator.schema(for: Int.self)
        return .tagged([
            "hostCommand": .properties(["hostID": string, "command": string, "token": generator.schema(for: TokenKind.self)],
                                       required: ["hostID", "command"]),
            "localCommand": .properties(["_0": generator.schema(for: CommandInvocation.self)]),
            "cancelRun": .properties(["id": int]),
            "deleteRunnerRegistration": .properties(["id": int, "name": string]),
        ])
    }
    public static var schemaExample: PlanAction { .cancelRun(id: 0) }
}

extension Precondition: SchemaDescribed {
    public static func jsonSchema(_ generator: SchemaGenerator) -> JSONValue {
        let string = generator.schema(for: String.self), int = generator.schema(for: Int.self)
        return .tagged([
            "runnerIdle": .properties(["name": string]), "runnerOffline": .properties(["name": string]),
            "runnerRegistered": .properties(["name": string]),
            "serviceNotRunning": .properties(["hostID": string, "runner": string]),
            "hostMayTakeJobs": .properties(["hostID": string]), "runActive": .properties(["id": int]),
            "fleetIdle": .properties(["prefix": string]),
        ])
    }
    public static var schemaExample: Precondition { .runActive(id: 0) }
}
