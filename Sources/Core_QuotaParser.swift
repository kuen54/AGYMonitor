import Foundation

// MARK: - Antigravity Quota, Plan & Credits Parsers — pure core
//
// Pure Foundation-only decoders for Google Antigravity's three quota/account
// surfaces:
//   1. `state.vscdb` (`ItemTable`) protobuf sync blobs:
//      - `antigravityUnifiedStateSync.userStatus` (outer base64 protobuf wrapper
//        with `userStatusSentinelKey` -> inner base64 `UserStatus` proto carrying
//        email, plan tier, prompt/flow/flex AI credits, and `cascade_model_config_data`
//        per-model `QuotaInfo { remaining_fraction, reset_time }`)
//      - `antigravityUnifiedStateSync.modelCredits` (`minimumCreditAmountForUsageKey`
//        -> inner credit amount)
//   2. Cloud Code PA JSON responses (`v1internal:fetchAvailableModels`,
//      `v1internal:retrieveUserQuotaSummary`, `v1internal:loadCodeAssist`)
//   3. `~/.gemini/antigravity-cli/log/cli-*.log` account email & tier lines +
//      `agy models` CLI tabular output.
//
// Zero SQLite, zero network, zero file I/O, zero AppKit/SwiftUI.

public struct AGYModelQuotaBucket: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let remainingFraction: Double
    public let resetAt: Date?
    public let modelClasses: [ModelClass]

    public var remainingPercent: Int {
        max(0, min(100, Int((remainingFraction * 100.0).rounded())))
    }

    public var usedPercent: Int {
        max(0, min(100, 100 - remainingPercent))
    }

    public init(
        id: String,
        title: String,
        remainingFraction: Double,
        resetAt: Date?,
        modelClasses: [ModelClass]
    ) {
        self.id = id
        self.title = title
        self.remainingFraction = min(1.0, max(0.0, remainingFraction))
        self.resetAt = resetAt
        self.modelClasses = modelClasses
    }
}

public struct AGYDecodedUserStatus: Codable, Equatable, Sendable {
    public let email: String?
    public let planName: String?
    public let promptCredits: Int?
    public let flowCredits: Int?
    public let flexCredits: Int?
    public let buckets: [AGYModelQuotaBucket]

    public init(
        email: String? = nil,
        planName: String? = nil,
        promptCredits: Int? = nil,
        flowCredits: Int? = nil,
        flexCredits: Int? = nil,
        buckets: [AGYModelQuotaBucket] = []
    ) {
        self.email = email
        self.planName = planName
        self.promptCredits = promptCredits
        self.flowCredits = flowCredits
        self.flexCredits = flexCredits
        self.buckets = buckets
    }
}

// MARK: - Pure Protobuf Wire-Format Reader (and Test Builder)

public enum ProtobufWire {
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case lengthDelimited(Data)
        case fixed32(UInt32)
    }

    public struct Field: Equatable, Sendable {
        public let number: Int
        public let value: Value

        public init(number: Int, value: Value) {
            self.number = number
            self.value = value
        }
    }

    public struct Message: Equatable, Sendable {
        public let fields: [Field]

        public init(fields: [Field]) {
            self.fields = fields
        }

        public func varint(_ fieldNumber: Int) -> UInt64? {
            for f in fields where f.number == fieldNumber {
                if case .varint(let v) = f.value { return v }
            }
            return nil
        }

        public func float32(_ fieldNumber: Int) -> Float? {
            for f in fields where f.number == fieldNumber {
                if case .fixed32(let bits) = f.value {
                    let fval = Float(bitPattern: bits)
                    if fval.isFinite { return fval }
                }
            }
            return nil
        }

        public func float64(_ fieldNumber: Int) -> Double? {
            for f in fields where f.number == fieldNumber {
                if case .fixed64(let bits) = f.value {
                    let dval = Double(bitPattern: bits)
                    if dval.isFinite { return dval }
                }
            }
            return nil
        }

        public func floatingPoint(_ fieldNumber: Int) -> Double? {
            if let f32 = float32(fieldNumber) {
                // Round 32-bit IEEE754 float noise (e.g. Float(0.99) -> 0.9900000095)
                return (Double(f32) * 1_000_000.0).rounded() / 1_000_000.0
            }
            if let f64 = float64(fieldNumber) {
                return f64
            }
            return nil
        }

        public func dataValues(_ fieldNumber: Int) -> [Data] {
            var out: [Data] = []
            for f in fields where f.number == fieldNumber {
                if case .lengthDelimited(let d) = f.value { out.append(d) }
            }
            return out
        }

        public func data(_ fieldNumber: Int) -> Data? {
            dataValues(fieldNumber).first
        }

        public func string(_ fieldNumber: Int) -> String? {
            for d in dataValues(fieldNumber) {
                if let s = ProtobufWire.utf8PrintableString(d) { return s }
            }
            return nil
        }

        public func submessage(_ fieldNumber: Int) -> Message? {
            guard let d = data(fieldNumber) else { return nil }
            return ProtobufWire.parse(d)
        }

        public func submessages(_ fieldNumber: Int) -> [Message] {
            dataValues(fieldNumber).compactMap(ProtobufWire.parse)
        }
    }

    /// Decode a binary protobuf message into wire fields. Never traps on
    /// truncated or malformed input — returns nil on any wire error.
    public static func parse(_ data: Data) -> Message? {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Field] = []

        while index < bytes.count {
            guard let tag = readVarint(bytes, index: &index) else { return nil }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            guard fieldNumber >= 1 else { return nil }

            switch wireType {
            case 0: // varint
                guard let v = readVarint(bytes, index: &index) else { return nil }
                fields.append(Field(number: fieldNumber, value: .varint(v)))
            case 1: // 64-bit little-endian
                guard index + 8 <= bytes.count else { return nil }
                var v: UInt64 = 0
                for offset in 0..<8 {
                    v |= UInt64(bytes[index + offset]) << (offset * 8)
                }
                index += 8
                fields.append(Field(number: fieldNumber, value: .fixed64(v)))
            case 2: // length-delimited
                guard let rawLen = readVarint(bytes, index: &index),
                      rawLen <= UInt64(bytes.count - index) else { return nil }
                let len = Int(rawLen)
                let slice = Data(bytes[index..<(index + len)])
                index += len
                fields.append(Field(number: fieldNumber, value: .lengthDelimited(slice)))
            case 5: // 32-bit little-endian
                guard index + 4 <= bytes.count else { return nil }
                var v: UInt32 = 0
                for offset in 0..<4 {
                    v |= UInt32(bytes[index + offset]) << (offset * 8)
                }
                index += 4
                fields.append(Field(number: fieldNumber, value: .fixed32(v)))
            default:
                // Unsupported / deprecated group wire types (3, 4, 6, 7)
                return nil
            }
        }
        return Message(fields: fields)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count && shift < 64 {
            let b = bytes[index]
            index += 1
            if shift == 63 && (b & 0xFE) != 0 {
                return nil // overflow > 64 bits
            }
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    /// Strict UTF-8 printable text check (rejects binary embedded messages whose bytes
    /// happen to be valid UTF-8 with control characters like 0x08 / 0x12).
    public static func utf8PrintableString(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D {
                return nil
            }
            if v == 0x7F {
                return nil
            }
        }
        return s
    }

    // MARK: Wire encoding helpers (used in unit tests to synthesize exact blobs)

    public static func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while v >= 0x80 {
            out.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    public static func encodeTag(fieldNumber: Int, wireType: Int) -> Data {
        encodeVarint(UInt64((fieldNumber << 3) | (wireType & 0x07)))
    }

    public static func encodeVarintField(_ fieldNumber: Int, _ value: UInt64) -> Data {
        encodeTag(fieldNumber: fieldNumber, wireType: 0) + encodeVarint(value)
    }

    public static func encodeFloat32Field(_ fieldNumber: Int, _ value: Float) -> Data {
        var out = encodeTag(fieldNumber: fieldNumber, wireType: 5)
        let bits = value.bitPattern
        for offset in 0..<4 {
            out.append(UInt8((bits >> (offset * 8)) & 0xFF))
        }
        return out
    }

    public static func encodeFloat64Field(_ fieldNumber: Int, _ value: Double) -> Data {
        var out = encodeTag(fieldNumber: fieldNumber, wireType: 1)
        let bits = value.bitPattern
        for offset in 0..<8 {
            out.append(UInt8((bits >> (offset * 8)) & 0xFF))
        }
        return out
    }

    public static func encodeBytesField(_ fieldNumber: Int, _ bytes: Data) -> Data {
        encodeTag(fieldNumber: fieldNumber, wireType: 2) + encodeVarint(UInt64(bytes.count)) + bytes
    }

    public static func encodeStringField(_ fieldNumber: Int, _ text: String) -> Data {
        encodeBytesField(fieldNumber, Data(text.utf8))
    }
}

// MARK: - AGYQuotaParser

public enum AGYQuotaParser {

    // MARK: 1) state.vscdb `antigravityUnifiedStateSync.userStatus`

    /// Decode `antigravityUnifiedStateSync.userStatus` from `state.vscdb` (outer
    /// `UnifiedStateSync` base64 protobuf wrapper -> inner `UserStatus` protobuf).
    /// Also accepts an unwrapped base64 `UserStatus` protobuf directly.
    public static func parseUserStatusValue(_ base64Wrapper: String) -> AGYDecodedUserStatus? {
        guard let unwrapped = unwrapUnifiedStateSync(
            base64Wrapper,
            expectedSentinel: "userStatusSentinelKey"
        ) else {
            return nil
        }

        if unwrapped.payload.isEmpty {
            return unwrapped.foundSentinel ? AGYDecodedUserStatus() : nil
        }
        guard let msg = ProtobufWire.parse(unwrapped.payload) else { return nil }

        let email = extractEmail(from: msg)
        let (planFromStatus, promptCredits, flowCredits, flexCredits) = extractPlanStatus(from: msg)
        let userTierName = extractUserTierName(from: msg)
        let planName = formatPlanTier(userTierName ?? planFromStatus)

        let rawSamples = extractModelQuotaSamples(from: msg)
        let buckets = aggregateModelQuotaSamples(rawSamples)

        let hasAnyData = email != nil
            || planName != nil
            || promptCredits != nil
            || flowCredits != nil
            || flexCredits != nil
            || !buckets.isEmpty

        guard hasAnyData || unwrapped.foundSentinel else { return nil }
        return AGYDecodedUserStatus(
            email: email,
            planName: planName,
            promptCredits: promptCredits,
            flowCredits: flowCredits,
            flexCredits: flexCredits,
            buckets: buckets
        )
    }

    // MARK: 2) state.vscdb `antigravityUnifiedStateSync.modelCredits`

    /// Decode `antigravityUnifiedStateSync.modelCredits` from `state.vscdb`
    /// (`minimumCreditAmountForUsageKey` -> `credit_amount` integer).
    public static func parseModelCreditsValue(_ base64Wrapper: String) -> Int? {
        let trimmed = stripSurroundingQuotes(base64Wrapper.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }
        if let directInt = Int(trimmed), directInt >= 0 {
            return directInt
        }

        guard let unwrapped = unwrapUnifiedStateSync(
            trimmed,
            expectedSentinel: "minimumCreditAmountForUsageKey"
        ) else {
            return nil
        }

        if unwrapped.payload.isEmpty {
            // In proto3, a message `{ int32 credit_amount = 1; }` with credit_amount == 0
            // serializes to 0 bytes inside a valid sentinel wrapper.
            return unwrapped.foundSentinel ? 0 : nil
        }

        if let s = ProtobufWire.utf8PrintableString(unwrapped.payload)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let n = Int(s), n >= 0 {
            return n
        }

        guard let msg = ProtobufWire.parse(unwrapped.payload) else { return nil }
        if let v1 = msg.varint(1) {
            return Int(clamping: v1)
        }
        for f in msg.fields {
            if case .varint(let v) = f.value {
                return Int(clamping: v)
            }
        }
        // Check one nested message level if wrapped once more.
        for f in msg.fields {
            if case .lengthDelimited(let subData) = f.value,
               let sub = ProtobufWire.parse(subData) {
                for sf in sub.fields {
                    if case .varint(let v) = sf.value {
                        return Int(clamping: v)
                    }
                }
            }
        }
        return unwrapped.foundSentinel ? 0 : nil
    }

    // MARK: 3) Cloud Code PA `fetchAvailableModels` / `retrieveUserQuotaSummary` JSON

    /// Decode Cloud Code PA JSON responses (`fetchAvailableModels` with `models` map/array
    /// OR `retrieveUserQuotaSummary` with `groups[].buckets[]` / `buckets[]`) into
    /// normalized, sorted `[AGYModelQuotaBucket]`.
    public static func parseAvailableModelsJSON(_ data: Data) -> [AGYModelQuotaBucket] {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Shape B: `retrieveUserQuotaSummary` (`groups[].buckets[]` or top-level `buckets[]`)
        let explicitBuckets = parseQuotaSummaryBuckets(root)
        if !explicitBuckets.isEmpty {
            return explicitBuckets
        }

        // Shape A: `fetchAvailableModels` (`models` dictionary or array)
        var samples: [ModelQuotaSample] = []
        if let modelsDict = root["models"] as? [String: Any] {
            for modelKey in modelsDict.keys.sorted() {
                guard let entry = modelsDict[modelKey] as? [String: Any] else { continue }
                if let sample = parseJSONModelEntry(defaultId: modelKey, entry: entry) {
                    samples.append(sample)
                }
            }
        } else if let modelsArr = root["models"] as? [[String: Any]] {
            for entry in modelsArr {
                let id = (entry["name"] as? String)
                    ?? (entry["modelId"] as? String)
                    ?? (entry["id"] as? String)
                    ?? ""
                if let sample = parseJSONModelEntry(defaultId: id, entry: entry) {
                    samples.append(sample)
                }
            }
        }

        return aggregateModelQuotaSamples(samples)
    }

    /// Merge live buckets from `v1internal:fetchAvailableModels` (which holds Gemini's
    /// 5h rolling quota), `v1internal:retrieveUserQuotaSummary` (3P "Claude and GPT models"
    /// 5h + weekly buckets), and `aicode.googleapis.com/v1alpha:fetchQuotaStatus` (all
    /// Gemini + 3P 5h/weekly buckets).
    public static func mergeLiveQuotaBuckets(
        availableModelsData: Data?,
        quotaSummaryData: Data?,
        aicodeQuotaData: Data? = nil
    ) -> [AGYModelQuotaBucket] {
        let modelBuckets = availableModelsData.map(parseAvailableModelsJSON) ?? []
        let summaryBuckets = quotaSummaryData.map(parseAvailableModelsJSON) ?? []
        let aicodeBuckets = aicodeQuotaData.map(parseAvailableModelsJSON) ?? []

        var merged: [String: AGYModelQuotaBucket] = [:]
        for bucket in modelBuckets {
            merged[bucket.id] = bucket
        }
        for bucket in summaryBuckets {
            merged[bucket.id] = bucket
        }
        for bucket in aicodeBuckets {
            merged[bucket.id] = bucket
        }
        return merged.values.sorted(by: bucketSortOrder)
    }

    // MARK: 3b) `agi` / `agy` Keychain OAuth payload (`go-keyring-base64:`)

    /// Parse macOS Keychain secret stored by `agy` CLI (`service="gemini", account="antigravity"`).
    /// Supports `zalando/go-keyring`'s `"go-keyring-base64:<b64 JSON>"` format, raw JSON, and
    /// hex-encoded output from `/usr/bin/security ... -w`.
    public static func parseGoKeyringAuthPayload(
        _ raw: String
    ) -> (accessToken: String?, expiry: Date?, email: String?)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let hexDecoded = decodeHexUTF8IfNeeded(text) {
            text = hexDecoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let jsonData: Data
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            let b64 = String(text.dropFirst(prefix.count))
            guard let decoded = decodeBase64Strict(b64) else { return nil }
            jsonData = decoded
        } else {
            guard let d = text.data(using: .utf8) else { return nil }
            jsonData = d
        }

        guard let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        let tokenObj = dict["token"] as? [String: Any]
        let rawToken = (tokenObj?["access_token"] as? String)
            ?? (tokenObj?["accessToken"] as? String)
            ?? (dict["access_token"] as? String)
            ?? (dict["accessToken"] as? String)
        let accessToken = nonEmptyTrimmed(rawToken)

        let rawExpiry = (tokenObj?["expiry"] as? String) ?? (dict["expiry"] as? String)
        let expiry = rawExpiry.flatMap { AppDate.parseISO8601($0) }

        let rawEmail = (dict["id_token_email"] as? String) ?? (dict["email"] as? String)
        let email = nonEmptyTrimmed(rawEmail)

        guard accessToken != nil || email != nil else { return nil }
        return (accessToken: accessToken, expiry: expiry, email: email)
    }

    // MARK: 4) `~/.gemini/antigravity-cli/log/cli-*.log` account info

    /// Extract the newest `(email, tier)` pair logged by `agy` in `cli-*.log`.
    /// Handles key=value (`slog`), JSON log lines, and `LoadCodeAssist` tier strings.
    public static func parseCLILogAccountInfo(_ logText: String) -> (email: String?, tier: String?) {
        var foundEmail: String? = nil
        var foundTier: String? = nil

        for sub in logText.split(separator: "\n") {
            let line = String(sub)
            if let e = extractEmailFromLogLine(line) {
                foundEmail = e
            }
            if let t = extractTierFromLogLine(line) {
                foundTier = formatPlanTier(t)
            }
        }
        return (email: foundEmail, tier: foundTier)
    }

    // MARK: - Supplemental pure Cloud Code / CLI helpers

    /// Parse Cloud Code PA `v1internal:loadCodeAssist` response JSON.
    public static func parseLoadCodeAssistJSON(_ data: Data) -> (tier: String?, projectId: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let rawTier = extractTierString(from: root["paidTier"])
            ?? extractTierString(from: root["currentTier"])
            ?? (root["userTier"] as? String)
        let project: String? = {
            if let s = root["cloudaicompanionProject"] as? String, !s.isEmpty { return s }
            if let dict = root["cloudaicompanionProject"] as? [String: Any],
               let id = dict["id"] as? String, !id.isEmpty { return id }
            return nil
        }()
        return (tier: formatPlanTier(rawTier), projectId: project)
    }

    /// Parse stdout of `agy models` (`<model_id>\t<Display Name>` per line).
    public static func parseAGYModelsOutput(
        _ output: String
    ) -> [(id: String, displayName: String, modelClass: ModelClass)] {
        var out: [(id: String, displayName: String, modelClass: ModelClass)] = []
        for sub in output.split(separator: "\n") {
            let line = sub.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "\t", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            let id = parts[0]
            guard !id.isEmpty, !id.contains(" ") else { continue }
            let display = parts.count > 1 && !parts[1].isEmpty ? parts[1] : id
            out.append((id: id, displayName: display, modelClass: ModelClass.classify(id + " " + display)))
        }
        return out
    }

    /// Normalize raw tier codes (`"G1_PRO_TIER"`, `"g1-ultra-tier"`, `"FREE_TIER"`,
    /// `"ENTERPRISE_AGENT_TIER"`, `"TEAMS_TIER_PRO"`) into clean UI labels.
    public static func formatPlanTier(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let norm = trimmed.uppercased().replacingOccurrences(of: "-", with: "_")
        switch norm {
        case "G1_PRO_TIER", "G1_PRO_LITE_TIER", "GOOGLE_ONE_AI_PRO", "GOOGLE_AI_PRO":
            return "Google AI Pro"
        case "G1_ULTRA_TIER", "G1_ULTRA_LITE_TIER", "GOOGLE_ONE_AI_ULTRA", "GOOGLE_AI_ULTRA":
            return "Google AI Ultra"
        case "FREE_TIER", "STANDARD_TIER_FREE", "TEAMS_TIER_FREE", "FREE":
            return "Free"
        case "ENTERPRISE_AGENT_TIER", "ENTERPRISE_TIER", "TEAMS_TIER_ENTERPRISE", "ENTERPRISE":
            return "Enterprise"
        case "TEAMS_TIER_PRO", "PRO_TIER":
            return "Pro"
        case "TEAMS_TIER_TEAMS", "TEAMS_TIER":
            return "Teams"
        default:
            // If UPPER_SNAKE_CASE with `_TIER`, humanize cleanly.
            if trimmed == trimmed.uppercased() && norm.contains("_") {
                let words = norm
                    .split(separator: "_")
                    .filter { $0 != "TIER" && $0 != "TEAMS" }
                    .map { w -> String in
                        if w == "G1" { return "Google AI" }
                        if w == "AI" { return "AI" }
                        return w.prefix(1).uppercased() + w.dropFirst().lowercased()
                    }
                let joined = words.joined(separator: " ")
                return joined.isEmpty ? trimmed : joined
            }
            return trimmed
        }
    }

    // MARK: - Internal helpers: Base64 & UnifiedStateSync unwrapping

    private static func nonEmptyTrimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }

    private static func decodeHexUTF8IfNeeded(_ raw: String) -> String? {
        guard !raw.hasPrefix("{"),
              !raw.hasPrefix("go-keyring-base64:"),
              raw.count >= 4,
              raw.count % 2 == 0 else {
            return nil
        }
        let bytes = Array(raw.utf8)
        func hexNibble(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48         // 0-9
            case 65...70: return b - 65 + 10    // A-F
            case 97...102: return b - 97 + 10   // a-f
            default: return nil
            }
        }
        var out = Data()
        out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i < bytes.count {
            guard let hi = hexNibble(bytes[i]), let lo = hexNibble(bytes[i + 1]) else {
                return nil
            }
            out.append((hi << 4) | lo)
            i += 2
        }
        return String(data: out, encoding: .utf8)
    }

    private static func stripSurroundingQuotes(_ s: String) -> String {
        if s.count >= 2 && s.first == "\"" && s.last == "\"" {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func decodeBase64Strict(_ raw: String) -> Data? {
        let stripped = stripSurroundingQuotes(raw)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !stripped.isEmpty else { return nil }

        var std = stripped
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        for scalar in std.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 65 && v <= 90)    // A-Z
                || (v >= 97 && v <= 122)     // a-z
                || (v >= 48 && v <= 57)      // 0-9
                || v == 43 || v == 47 || v == 61 // + / =
            if !ok { return nil }
        }

        let rem = std.count % 4
        if rem == 1 { return nil }
        if rem > 0 {
            std += String(repeating: "=", count: 4 - rem)
        }
        return Data(base64Encoded: std)
    }

    private static func unwrapUnifiedStateSync(
        _ wrapper: String,
        expectedSentinel: String
    ) -> (foundSentinel: Bool, payload: Data)? {
        guard let outerData = decodeBase64Strict(wrapper) else { return nil }
        guard let outerMsg = ProtobufWire.parse(outerData) else { return nil }

        // Search root and nested topic/map entry messages for the sentinel key.
        if let hit = extractSentinelEntry(from: outerMsg, sentinel: expectedSentinel) {
            return (true, hit)
        }
        for f in outerMsg.fields {
            if case .lengthDelimited(let d) = f.value, let sub = ProtobufWire.parse(d) {
                if let hit = extractSentinelEntry(from: sub, sentinel: expectedSentinel) {
                    return (true, hit)
                }
                for sf in sub.fields {
                    if case .lengthDelimited(let d2) = sf.value,
                       let sub2 = ProtobufWire.parse(d2),
                       let hit = extractSentinelEntry(from: sub2, sentinel: expectedSentinel) {
                        return (true, hit)
                    }
                }
            }
        }

        // Generic UnifiedStateSync fallback: `{ f1 = "<anySentinelKey>", f2 = { f1 = "<base64>" } }`
        if let f1 = outerMsg.string(1),
           f1.lowercased().contains("key"),
           let payload = extractValuePayload(from: outerMsg) {
            return (true, payload)
        }

        // Unwrapped inner protobuf passed directly.
        return (false, outerData)
    }

    private static func extractSentinelEntry(
        from msg: ProtobufWire.Message,
        sentinel: String
    ) -> Data? {
        let hasSentinel = msg.fields.contains { f in
            guard case .lengthDelimited(let d) = f.value,
                  let s = ProtobufWire.utf8PrintableString(d) else { return false }
            return s == sentinel
        }
        guard hasSentinel else { return nil }
        return extractValuePayload(from: msg) ?? Data()
    }

    private static func extractValuePayload(from entryMsg: ProtobufWire.Message) -> Data? {
        for d in entryMsg.dataValues(2) {
            if d.isEmpty { return Data() }
            if let valueMsg = ProtobufWire.parse(d) {
                if valueMsg.fields.isEmpty { return Data() }
                // Standard `f2.f1` = inner base64 protobuf string
                if let b64 = valueMsg.string(1) {
                    if b64.isEmpty { return Data() }
                    if let decoded = decodeBase64Strict(b64) { return decoded }
                }
                for vf in valueMsg.fields {
                    if case .lengthDelimited(let vd) = vf.value,
                       let s = ProtobufWire.utf8PrintableString(vd),
                       let decoded = decodeBase64Strict(s), !decoded.isEmpty {
                        return decoded
                    }
                }
                // Embedded binary message directly inside `f2`
                return d
            }
            if let s = ProtobufWire.utf8PrintableString(d),
               let decoded = decodeBase64Strict(s) {
                return decoded
            }
            return d
        }
        return nil
    }

    // MARK: - Internal helpers: UserStatus field extraction

    private static func looksLikeEmail(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, trimmed.count <= 254,
              !trimmed.contains(" "), !trimmed.contains("/"), !trimmed.contains("\n") else {
            return false
        }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix(".") else {
            return false
        }
        return true
    }

    private static func extractEmail(from userStatus: ProtobufWire.Message) -> String? {
        if let f7 = userStatus.string(7), looksLikeEmail(f7) {
            return f7.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for f in userStatus.fields {
            if case .lengthDelimited(let d) = f.value,
               let s = ProtobufWire.utf8PrintableString(d),
               looksLikeEmail(s) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func decodeProtoTimestamp(_ data: Data) -> Date? {
        if let str = ProtobufWire.utf8PrintableString(data),
           let iso = AppDate.parseISO8601(str) {
            return iso
        }
        guard let msg = ProtobufWire.parse(data), !msg.fields.isEmpty else { return nil }
        for f in msg.fields where f.number > 2 { return nil }
        guard let sec = msg.varint(1) else { return nil }
        // Plausible epoch range: 2020-01-01 .. 2100-01-01
        guard sec >= 1_577_836_800 && sec <= 4_102_444_800 else { return nil }
        let nanos = msg.varint(2) ?? 0
        guard nanos < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(sec) + Double(nanos) / 1_000_000_000.0)
    }

    private static func extractPlanStatus(
        from userStatus: ProtobufWire.Message
    ) -> (planName: String?, promptCredits: Int?, flowCredits: Int?, flexCredits: Int?) {
        var candidates: [ProtobufWire.Message] = []
        if let f8 = userStatus.submessage(8) {
            candidates.append(f8)
        }
        for f in userStatus.fields where f.number != 8 && f.number != 33 {
            if case .lengthDelimited(let d) = f.value,
               let sub = ProtobufWire.parse(d),
               sub.submessages(1).count <= 1 {
                let hasPlanTimestamp = (sub.data(2).flatMap(decodeProtoTimestamp) != nil)
                    || (sub.data(3).flatMap(decodeProtoTimestamp) != nil)
                    || (sub.data(5).flatMap(decodeProtoTimestamp) != nil)
                if hasPlanTimestamp {
                    candidates.append(sub)
                }
            }
        }

        for planMsg in candidates {
            var planName: String? = nil
            if let planInfo = planMsg.submessage(1) {
                planName = planInfo.string(2) ?? planInfo.string(1) ?? planInfo.string(3)
            }

            let prompt: Int?
            let flow: Int?
            let flex: Int?
            // Disambiguate `{ plan_info=1, plan_start=2(msg), plan_end=3(msg), prompt=4, flow=5, flex=6 }`
            // vs `{ plan_info=1, prompt=2(varint), flow=3(varint), flex=4(varint), plan_start=5(msg), plan_end=6(msg) }`.
            if planMsg.varint(2) != nil || (planMsg.varint(3) != nil && planMsg.data(2) == nil) {
                prompt = planMsg.varint(2).map { Int(clamping: $0) }
                flow   = planMsg.varint(3).map { Int(clamping: $0) }
                flex   = planMsg.varint(4).map { Int(clamping: $0) }
            } else {
                prompt = planMsg.varint(4).map { Int(clamping: $0) }
                flow   = planMsg.varint(5).map { Int(clamping: $0) }
                flex   = (planMsg.varint(6) ?? planMsg.varint(7)).map { Int(clamping: $0) }
            }

            if planName != nil || prompt != nil || flow != nil || flex != nil {
                return (planName, prompt, flow, flex)
            }
        }
        return (nil, nil, nil, nil)
    }

    private static func extractUserTierName(from userStatus: ProtobufWire.Message) -> String? {
        // UserTier message typically sits at field 13..40 with `{ string id = 1; string name = 2; }`
        // e.g. `f1 = "g1-pro-tier"`, `f2 = "Google AI Pro"`.
        for f in userStatus.fields where f.number >= 10 && f.number != 33 {
            guard case .lengthDelimited(let d) = f.value,
                  let sub = ProtobufWire.parse(d) else { continue }
            let s1 = sub.string(1)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let s2 = sub.string(2)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = s1,
               (id.lowercased().contains("tier") || id.lowercased().hasPrefix("g1-") || id.lowercased().contains("ultra") || id.lowercased().contains("pro")) {
                if let display = s2, !display.isEmpty, display.count <= 48, !looksLikeEmail(display) {
                    return display
                }
                return id
            }
        }
        return nil
    }

    // MARK: - Internal helpers: Per-model QuotaInfo extraction & bucket aggregation

    private struct ModelQuotaSample {
        let modelIdentifier: String
        let explicitBucketId: String?
        let explicitBucketTitle: String?
        let remainingFraction: Double
        let resetAt: Date?
    }

    private static func extractModelQuotaSamples(from userStatus: ProtobufWire.Message) -> [ModelQuotaSample] {
        var samples: [ModelQuotaSample] = []

        // Check `cascade_model_config_data` (f33) first, then any other container message
        // holding repeated `ClientModelConfig` in `f1` (or direct `ClientModelConfig` entries).
        var configMessages: [ProtobufWire.Message] = []
        if let cascade = userStatus.submessage(33) {
            configMessages.append(contentsOf: cascade.submessages(1))
        }
        if configMessages.isEmpty {
            for f in userStatus.fields where f.number != 8 {
                guard case .lengthDelimited(let d) = f.value,
                      let sub = ProtobufWire.parse(d) else { continue }
                let nestedConfigs = sub.submessages(1)
                if nestedConfigs.contains(where: { extractSingleModelConfig($0) != nil }) {
                    configMessages.append(contentsOf: nestedConfigs)
                } else if extractSingleModelConfig(sub) != nil {
                    configMessages.append(sub)
                }
            }
        }

        for cfg in configMessages {
            if let sample = extractSingleModelConfig(cfg) {
                samples.append(sample)
            }
        }
        return samples
    }

    private static func extractSingleModelConfig(_ cfg: ProtobufWire.Message) -> ModelQuotaSample? {
        // Model label/id: `f1` is label ("Gemini 4 Carbon (Medium)"); also check string
        // fields in `f2` (`ModelOrAlias`) or direct string fields.
        var nameParts: [String] = []
        if let label = cfg.string(1), !label.isEmpty {
            nameParts.append(label)
        }
        if let sub2 = cfg.submessage(2), let alias = sub2.string(1), !alias.isEmpty {
            nameParts.append(alias)
        } else if let s2 = cfg.string(2), !s2.isEmpty {
            nameParts.append(s2)
        }
        guard !nameParts.isEmpty else { return nil }
        let combinedName = nameParts.joined(separator: " ")

        // `ClientModelConfig.quota_info` is `f15` (`QuotaInfo { float remaining_fraction = 1; reset_time = 2; }`).
        if let q15 = cfg.submessage(15),
           let decoded = decodeQuotaInfo(q15, strict: false) {
            return ModelQuotaSample(
                modelIdentifier: combinedName,
                explicitBucketId: decoded.bucketName,
                explicitBucketTitle: nil,
                remainingFraction: decoded.remaining,
                resetAt: decoded.resetAt
            )
        }

        // Fallback: check other submessages (`f3...f30`) with strict `QuotaInfo` signature.
        for f in cfg.fields where f.number >= 3 && f.number != 15 {
            guard case .lengthDelimited(let d) = f.value,
                  let sub = ProtobufWire.parse(d),
                  let decoded = decodeQuotaInfo(sub, strict: true) else { continue }
            return ModelQuotaSample(
                modelIdentifier: combinedName,
                explicitBucketId: decoded.bucketName,
                explicitBucketTitle: nil,
                remainingFraction: decoded.remaining,
                resetAt: decoded.resetAt
            )
        }
        return nil
    }

    private static func decodeQuotaInfo(
        _ q: ProtobufWire.Message,
        strict: Bool
    ) -> (remaining: Double, resetAt: Date?, bucketName: String?)? {
        if strict {
            for f in q.fields where f.number > 4 { return nil }
        }
        let rawRemaining = q.floatingPoint(1)
        if let r = rawRemaining, (r < -0.001 || r > 1.001) {
            return nil
        }
        let resetAt = q.data(2).flatMap(decodeProtoTimestamp)
        // If `f2` was present in strict mode, it MUST decode as a valid timestamp.
        if strict, q.data(2) != nil && resetAt == nil {
            return nil
        }

        let bucketName = q.string(3)
        if let r = rawRemaining {
            if strict && resetAt == nil {
                // Only accept single-field float32/float64 in [0, 1] when no unrelated varint/bytes exist.
                let onlyFloat = q.fields.allSatisfy {
                    if $0.number == 1 {
                        switch $0.value {
                        case .fixed32, .fixed64: return true
                        default: return false
                        }
                    }
                    return $0.number == 3
                }
                guard onlyFloat else { return nil }
            }
            return (min(1.0, max(0.0, r)), resetAt, bucketName)
        }
        if let resetAt = resetAt {
            // Proto3 omits `remaining_fraction = 0.0` default when quota is 0% remaining!
            if strict {
                let validZeroQuota = q.fields.allSatisfy { $0.number == 2 || $0.number == 3 }
                guard validZeroQuota else { return nil }
            }
            return (0.0, resetAt, bucketName)
        }
        return nil
    }

    private static func parseJSONModelEntry(
        defaultId: String,
        entry: [String: Any]
    ) -> ModelQuotaSample? {
        let lowerDefaultId = defaultId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowerDefaultId.hasPrefix("chat_") || lowerDefaultId.hasPrefix("tab_") {
            return nil
        }
        let displayName = (entry["displayName"] as? String)
            ?? (entry["display_name"] as? String)
            ?? (entry["label"] as? String)
            ?? ""
        let identifier = "\(defaultId) \(displayName)".trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty else { return nil }

        guard let qInfo = (entry["quotaInfo"] as? [String: Any])
                ?? (entry["quota_info"] as? [String: Any]) else {
            return nil
        }

        let rawRem: Double? = {
            if let d = qInfo["remainingFraction"] as? Double { return d }
            if let i = qInfo["remainingFraction"] as? Int { return Double(i) }
            if let d = qInfo["remaining_fraction"] as? Double { return d }
            if let i = qInfo["remaining_fraction"] as? Int { return Double(i) }
            return nil
        }()
        let resetStr = (qInfo["resetTime"] as? String) ?? (qInfo["reset_time"] as? String)
        let resetAt = AppDate.parseISO8601(resetStr)

        guard rawRem != nil || resetAt != nil else { return nil }
        let remaining = min(1.0, max(0.0, rawRem ?? 0.0))

        let bucketName = (entry["quotaBucketName"] as? String)
            ?? (entry["quota_bucket_name"] as? String)
            ?? (qInfo["bucketName"] as? String)

        return ModelQuotaSample(
            modelIdentifier: identifier,
            explicitBucketId: bucketName,
            explicitBucketTitle: nil,
            remainingFraction: remaining,
            resetAt: resetAt
        )
    }

    private static func parseQuotaSummaryBuckets(_ root: [String: Any]) -> [AGYModelQuotaBucket] {
        let summaryRoot = (root["quotaSummary"] as? [String: Any])
            ?? (root["quota_summary"] as? [String: Any])
            ?? root

        var entries: [(groupTitle: String, groupDesc: String, bucket: [String: Any])] = []
        if let groups = summaryRoot["groups"] as? [[String: Any]] {
            for g in groups {
                let gTitle = (g["displayName"] as? String) ?? (g["display_name"] as? String) ?? ""
                let gDesc = (g["description"] as? String) ?? ""
                if let bList = g["buckets"] as? [[String: Any]] {
                    for b in bList {
                        entries.append((gTitle, gDesc, b))
                    }
                }
            }
        }
        if entries.isEmpty, let topBuckets = summaryRoot["buckets"] as? [[String: Any]] {
            for b in topBuckets {
                let hasSummaryKeys = (b["bucketId"] as? String) != nil
                    || (b["bucket_id"] as? String) != nil
                    || (b["window"] as? String) != nil
                    || (b["refreshWindowLabel"] as? String) != nil
                    || (b["refresh_window_label"] as? String) != nil
                if hasSummaryKeys {
                    entries.append(("", "", b))
                }
            }
        }
        guard !entries.isEmpty else { return [] }

        var results: [AGYModelQuotaBucket] = []
        for entry in entries {
            let b = entry.bucket
            if (b["disabled"] as? Bool) == true { continue }
            let rawId = (b["bucketId"] as? String)
                ?? (b["bucket_id"] as? String)
                ?? (b["id"] as? String)
                ?? ""
            let rawTitle = (b["displayName"] as? String)
                ?? (b["display_name"] as? String)
                ?? (b["title"] as? String)
                ?? ""
            guard !rawId.isEmpty || !rawTitle.isEmpty else { continue }

            let rem: Double = {
                if let d = b["remainingFraction"] as? Double { return d }
                if let i = b["remainingFraction"] as? Int { return Double(i) }
                if let d = b["remaining_fraction"] as? Double { return d }
                if let i = b["remaining_fraction"] as? Int { return Double(i) }
                return 1.0
            }()
            let resetAt = AppDate.parseISO8601(
                (b["resetTime"] as? String) ?? (b["reset_time"] as? String)
            )
            let window = ((b["window"] as? String)
                ?? (b["refreshWindowLabel"] as? String)
                ?? (b["refresh_window_label"] as? String)
                ?? "").lowercased()
            let lowerId = rawId.lowercased()
            let lowerTitle = rawTitle.lowercased()
            let isWeekly = window.contains("week") || lowerId.contains("week") || lowerTitle.contains("week")
            let familyProbe = "\(entry.groupTitle) \(entry.groupDesc) \(rawId) \(rawTitle)".lowercased()

            let isGemini = familyProbe.contains("gemini") || lowerId.hasPrefix("1p")
            let isClaudeOrGPT = familyProbe.contains("claude")
                || familyProbe.contains("gpt")
                || familyProbe.contains("partner")
                || familyProbe.contains("anthropic")
                || lowerId.hasPrefix("3p")

            let canonicalId: String
            let canonicalTitle: String
            let classes: [ModelClass]
            if isGemini && !isClaudeOrGPT {
                canonicalId = isWeekly ? "gemini_weekly" : "gemini"
                canonicalTitle = isWeekly ? "Gemini · Weekly" : "Gemini Models"
                classes = ModelClass.allCases.filter(\.isGeminiFamily)
            } else if isClaudeOrGPT {
                canonicalId = isWeekly ? "claude_partner_weekly" : "claude_partner"
                canonicalTitle = isWeekly ? "Claude & GPT · Weekly" : "Claude & GPT · 5h"
                classes = [.claude, .other]
            } else {
                let fallback = canonicalBucketMetadata(rawId: rawId, rawTitle: rawTitle, classes: [])
                canonicalId = fallback.id
                canonicalTitle = fallback.title
                classes = fallback.defaultClasses
            }

            results.append(AGYModelQuotaBucket(
                id: canonicalId,
                title: canonicalTitle,
                remainingFraction: rem,
                resetAt: resetAt,
                modelClasses: classes
            ))
        }

        return results.sorted(by: bucketSortOrder)
    }

    private static func aggregateModelQuotaSamples(_ samples: [ModelQuotaSample]) -> [AGYModelQuotaBucket] {
        guard !samples.isEmpty else { return [] }

        struct GroupAccum {
            var rawId: String
            var rawTitle: String?
            var minRemaining: Double
            var earliestReset: Date?
            var classes: Set<ModelClass>
        }

        var groups: [String: GroupAccum] = [:]
        for s in samples {
            let cls = ModelClass.classify(s.modelIdentifier)
            let key: String
            if let exp = s.explicitBucketId?.trimmingCharacters(in: .whitespacesAndNewlines), !exp.isEmpty {
                let lower = exp.lowercased()
                if lower.contains("gemini") {
                    key = "gemini"
                } else if lower.contains("claude") || lower.contains("partner") || lower.contains("anthropic") {
                    key = "claude_partner"
                } else {
                    key = lower
                }
            } else {
                key = cls.isGeminiFamily ? "gemini" : "claude_partner"
            }

            if var existing = groups[key] {
                existing.minRemaining = min(existing.minRemaining, s.remainingFraction)
                if let r = s.resetAt {
                    if let cur = existing.earliestReset {
                        existing.earliestReset = min(cur, r)
                    } else {
                        existing.earliestReset = r
                    }
                }
                existing.classes.insert(cls)
                groups[key] = existing
            } else {
                groups[key] = GroupAccum(
                    rawId: key,
                    rawTitle: s.explicitBucketTitle,
                    minRemaining: s.remainingFraction,
                    earliestReset: s.resetAt,
                    classes: [cls]
                )
            }
        }

        let buckets: [AGYModelQuotaBucket] = groups.values.map { g in
            let orderedClasses = ModelClass.allCases.filter { g.classes.contains($0) }
            let meta = canonicalBucketMetadata(
                rawId: g.rawId,
                rawTitle: g.rawTitle ?? "",
                classes: orderedClasses
            )
            return AGYModelQuotaBucket(
                id: meta.id,
                title: meta.title,
                remainingFraction: g.minRemaining,
                resetAt: g.earliestReset,
                modelClasses: orderedClasses.isEmpty ? meta.defaultClasses : orderedClasses
            )
        }

        return buckets.sorted(by: bucketSortOrder)
    }

    private static func canonicalBucketMetadata(
        rawId: String,
        rawTitle: String,
        classes: [ModelClass]
    ) -> (id: String, title: String, defaultClasses: [ModelClass]) {
        let probe = "\(rawId) \(rawTitle)".lowercased()
        if probe.contains("gemini") || (!classes.isEmpty && classes.allSatisfy(\.isGeminiFamily)) {
            let title = rawTitle.isEmpty ? "Gemini Models" : rawTitle
            return ("gemini", title, ModelClass.allCases.filter(\.isGeminiFamily))
        }
        if probe.contains("claude") || probe.contains("partner") || probe.contains("anthropic")
            || (!classes.isEmpty && classes.allSatisfy { !$0.isGeminiFamily }) {
            let title = rawTitle.isEmpty ? "Claude & Partner" : rawTitle
            return ("claude_partner", title, [.claude, .other])
        }
        let id = rawId.isEmpty ? rawTitle.lowercased().replacingOccurrences(of: " ", with: "_") : rawId
        let title = rawTitle.isEmpty ? rawId : rawTitle
        let inferred = classes.isEmpty ? [ModelClass.classify(probe)] : classes
        return (id, title, inferred)
    }

    private static func bucketSortOrder(_ a: AGYModelQuotaBucket, _ b: AGYModelQuotaBucket) -> Bool {
        func rank(_ id: String) -> Int {
            switch id {
            case "gemini": return 0
            case "gemini_weekly": return 1
            case "claude_partner": return 2
            case "claude_partner_weekly": return 3
            default: return 4
            }
        }
        let ra = rank(a.id), rb = rank(b.id)
        if ra != rb { return ra < rb }
        return a.id < b.id
    }

    // MARK: - Internal helpers: CLI log parsing

    private static func extractTierString(from any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let d = any as? [String: Any] {
            return (d["name"] as? String) ?? (d["id"] as? String) ?? (d["tierId"] as? String)
        }
        return nil
    }

    private static let emailRegex = try? NSRegularExpression(
        pattern: #"(?:email|account|user_email)\s*(?:=|:|"\s*:\s*")\s*"?([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})"?"#,
        options: [.caseInsensitive]
    )

    private static let tierKeyValueRegex = try? NSRegularExpression(
        pattern: #"(?:currentTier|userTier|user_tier|paidTier|planTier)\s*(?:=|:|"\s*:\s*")\s*"?([A-Za-z0-9_\- ]{2,40})"?"#,
        options: []
    )

    private static let knownTierTokenRegex = try? NSRegularExpression(
        pattern: #"\b(G1_PRO_TIER|G1_ULTRA_TIER|FREE_TIER|ENTERPRISE_AGENT_TIER|GOOGLE_ONE_AI_PRO|GOOGLE_ONE_AI_ULTRA)\b"#,
        options: [.caseInsensitive]
    )

    private static func extractEmailFromLogLine(_ line: String) -> String? {
        guard line.contains("@") else { return nil }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = emailRegex?.firstMatch(in: line, options: [], range: range),
           match.numberOfRanges >= 2 {
            let candidate = ns.substring(with: match.range(at: 1))
            if looksLikeEmail(candidate) { return candidate }
        }
        return nil
    }

    private static func extractTierFromLogLine(_ line: String) -> String? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = tierKeyValueRegex?.firstMatch(in: line, options: [], range: range),
           match.numberOfRanges >= 2 {
            let candidate = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty && candidate.lowercased() != "null" && candidate.lowercased() != "nil" {
                return candidate
            }
        }
        if let match = knownTierTokenRegex?.firstMatch(in: line, options: [], range: range),
           match.numberOfRanges >= 2 {
            return ns.substring(with: match.range(at: 1))
        }
        return nil
    }
}
