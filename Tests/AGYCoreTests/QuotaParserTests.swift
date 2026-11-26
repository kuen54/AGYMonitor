import Foundation
import Testing
@testable import AGYCore

@Suite("Core_QuotaParser")
struct QuotaParserTests {

    private func makeUnifiedSyncWrapper(sentinel: String, innerBytes: Data, nestedEntry: Bool = true) -> String {
        let innerB64 = innerBytes.base64EncodedString()
        let valueMsg = ProtobufWire.encodeStringField(1, innerB64)
        let entryMsg = ProtobufWire.encodeStringField(1, sentinel)
            + ProtobufWire.encodeBytesField(2, valueMsg)
        let outer = nestedEntry ? ProtobufWire.encodeBytesField(1, entryMsg) : entryMsg
        return outer.base64EncodedString()
    }

    private func makeModelConfigProto(label: String, remaining: Float?, resetISO: String?) -> Data {
        var quota = Data()
        if let r = remaining {
            quota += ProtobufWire.encodeFloat32Field(1, r)
        }
        if let iso = resetISO {
            quota += ProtobufWire.encodeStringField(2, iso)
        }
        return ProtobufWire.encodeStringField(1, label)
            + ProtobufWire.encodeBytesField(15, quota)
    }

    @Test("Decodes UnifiedStateSync.userStatus protobuf (email, tier, AI credits, Gemini & Claude buckets, and 0% proto3 default)")
    func parseUserStatusProtobuf() throws {
        // PlanInfo + PlanStatus (`f8`)
        let planInfo = ProtobufWire.encodeStringField(2, "Pro")
        let planStart = ProtobufWire.encodeVarintField(1, 1_793_491_200)
        let planEnd   = ProtobufWire.encodeVarintField(1, 1_796_083_200)
        let planStatus = ProtobufWire.encodeBytesField(1, planInfo)
            + ProtobufWire.encodeBytesField(2, planStart)
            + ProtobufWire.encodeBytesField(3, planEnd)
            + ProtobufWire.encodeVarintField(4, 1_500) // promptCredits
            + ProtobufWire.encodeVarintField(5, 4_000) // flowCredits
            + ProtobufWire.encodeVarintField(6, 750)   // flexCredits

        // UserTier (`f13`)
        let userTier = ProtobufWire.encodeStringField(1, "g1-pro-tier")
            + ProtobufWire.encodeStringField(2, "Google One AI Pro")

        // CascadeModelConfigData (`f33`) with Gemini models (99% left) & Claude/Partner (0% left proto3-omitted float!)
        let m1 = makeModelConfigProto(label: "Gemini 4 Carbon (Medium)", remaining: 0.99, resetISO: "2026-11-16T13:53:55Z")
        let m2 = makeModelConfigProto(label: "Orchestrator (Argon)", remaining: 0.99, resetISO: "2026-11-16T13:53:55Z")
        let m3 = makeModelConfigProto(label: "Claude Opus 5.5 (High)", remaining: nil, resetISO: "2026-11-16T16:46:16Z") // omitted 0.0!
        let m4 = makeModelConfigProto(label: "GPT-OSS 120B (Medium)", remaining: 1.0, resetISO: "2026-11-16T16:46:16Z")
        let cascade = ProtobufWire.encodeBytesField(1, m1)
            + ProtobufWire.encodeBytesField(1, m2)
            + ProtobufWire.encodeBytesField(1, m3)
            + ProtobufWire.encodeBytesField(1, m4)

        let userStatus = ProtobufWire.encodeStringField(3, "Demo User")
            + ProtobufWire.encodeStringField(7, "demo.user@example.com")
            + ProtobufWire.encodeBytesField(8, planStatus)
            + ProtobufWire.encodeBytesField(13, userTier)
            + ProtobufWire.encodeBytesField(33, cascade)

        let wrapped = makeUnifiedSyncWrapper(sentinel: "userStatusSentinelKey", innerBytes: userStatus)
        let decoded = try #require(AGYQuotaParser.parseUserStatusValue(wrapped))

        #expect(decoded.email == "demo.user@example.com")
        #expect(decoded.planName == "Google One AI Pro")
        #expect(decoded.promptCredits == 1_500)
        #expect(decoded.flowCredits == 4_000)
        #expect(decoded.flexCredits == 750)
        #expect(decoded.buckets.count == 2)

        let gemini = decoded.buckets[0]
        #expect(gemini.id == "gemini")
        #expect(gemini.title == "Gemini Models")
        #expect(gemini.remainingPercent == 99)
        #expect(gemini.usedPercent == 1)
        #expect(gemini.modelClasses == [.carbon, .argon])
        #expect(gemini.resetAt != nil)

        let claude = decoded.buckets[1]
        #expect(claude.id == "claude_partner")
        #expect(claude.title == "Claude & Partner")
        // min(0.0 from exhausted Claude Opus, 1.0 from GPT-OSS) == 0.0 -> 0% left
        #expect(claude.remainingPercent == 0)
        #expect(claude.usedPercent == 100)
        #expect(claude.modelClasses == [.claude, .other])
    }

    @Test("Decodes UnifiedStateSync.modelCredits for positive and proto3-zero values")
    func parseModelCreditsProtobuf() {
        let nonZeroInner = ProtobufWire.encodeVarintField(1, 500)
        let wrapped500 = makeUnifiedSyncWrapper(sentinel: "minimumCreditAmountForUsageKey", innerBytes: nonZeroInner)
        #expect(AGYQuotaParser.parseModelCreditsValue(wrapped500) == 500)

        // Proto3 default 0 serializes inner message as empty Data()
        let wrappedZero = makeUnifiedSyncWrapper(sentinel: "minimumCreditAmountForUsageKey", innerBytes: Data(), nestedEntry: false)
        #expect(AGYQuotaParser.parseModelCreditsValue(wrappedZero) == 0)

        // Malformed / non-base64 returns nil without crashing
        #expect(AGYQuotaParser.parseModelCreditsValue("not-valid-protobuf-$$$") == nil)
    }

    @Test("Parses Cloud Code PA fetchAvailableModels and retrieveUserQuotaSummary JSON")
    func parseCloudCodePAJSON() {
        let fetchModelsJSON = """
        {
          "models": {
            "gemini-4-hydrogen-high": {
              "displayName": "Gemini 4 Hydrogen (High)",
              "quotaInfo": { "remainingFraction": 0.84, "resetTime": "2026-11-16T15:00:00Z" },
              "quotaBucketName": "gemini"
            },
            "claude-sonnet-5-5-medium": {
              "displayName": "Claude Sonnet 5.5 (Medium)",
              "quotaInfo": { "remainingFraction": 0.92, "resetTime": "2026-11-16T16:30:00Z" },
              "quotaBucketName": "claude"
            }
          }
        }
        """
        let buckets1 = AGYQuotaParser.parseAvailableModelsJSON(Data(fetchModelsJSON.utf8))
        #expect(buckets1.count == 2)
        #expect(buckets1[0].id == "gemini")
        #expect(buckets1[0].remainingPercent == 84)
        #expect(buckets1[0].modelClasses == [.hydrogen])
        #expect(buckets1[1].id == "claude_partner")
        #expect(buckets1[1].remainingPercent == 92)
        #expect(buckets1[1].modelClasses == [.claude])

        let summaryJSON = """
        {
          "groups": [
            {
              "buckets": [
                {
                  "bucketId": "claude_partner",
                  "displayName": "Claude & Partner",
                  "remainingFraction": 1.0,
                  "resetTime": "0001-01-01T00:00:00Z",
                  "disabled": false
                },
                {
                  "bucketId": "gemini",
                  "displayName": "Gemini Models",
                  "remainingFraction": 0.75,
                  "resetTime": "2026-11-16T18:00:00Z",
                  "disabled": false
                }
              ]
            }
          ]
        }
        """
        let buckets2 = AGYQuotaParser.parseAvailableModelsJSON(Data(summaryJSON.utf8))
        #expect(buckets2.count == 2)
        // Sorted Gemini first, Claude & Partner second; sentinel resetTime becomes nil
        #expect(buckets2[0].id == "gemini")
        #expect(buckets2[0].remainingPercent == 75)
        #expect(buckets2[0].resetAt != nil)
        #expect(buckets2[1].id == "claude_partner")
        #expect(buckets2[1].resetAt == nil)
    }

    @Test("Parses cli-*.log account email & tier and agy models output")
    func parseCLILogsAndModelsOutput() {
        let logSample = """
        time=2026-11-16T19:45:00+08:00 level=INFO msg="authenticated session" email=dev@company.org authMethod=oauth
        time=2026-11-16T19:45:01+08:00 level=INFO msg="LoadCodeAssist" currentTier=G1_ULTRA_TIER
        """
        let info = AGYQuotaParser.parseCLILogAccountInfo(logSample)
        #expect(info.email == "dev@company.org")
        #expect(info.tier == "Google AI Ultra")

        let modelsStdout = """
        gemini-4-neon-high\tGemini 4 Neon (High)
        gemini-pro-orchestrator-neon\tOrchestrator (Neon)
        gemini-4-hydrogen-xhigh\tGemini 4 Hydrogen (XHigh)
        gemini-pro-orchestrator-argon\tOrchestrator (Argon)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
        """
        let rows = AGYQuotaParser.parseAGYModelsOutput(modelsStdout)
        #expect(rows.count == 5)
        #expect(rows[0].modelClass == .neon)
        #expect(rows[1].modelClass == .neon)
        #expect(rows[2].modelClass == .hydrogen)
        #expect(rows[3].modelClass == .argon)
        #expect(rows[4].modelClass == .other)
    }

    @Test("Buckets gemini-4-neon without explicit quotaBucketName into gemini instead of claude_partner")
    func bucketNeonIntoGeminiWithoutExplicitBucket() {
        let json = """
        {
          "models": {
            "gemini-4-neon-high": {
              "displayName": "Gemini 4 Neon (High)",
              "quotaInfo": { "remainingFraction": 0.78, "resetTime": "2026-11-19T12:00:00Z" }
            }
          }
        }
        """
        let buckets = AGYQuotaParser.parseAvailableModelsJSON(Data(json.utf8))
        #expect(buckets.count == 1)
        #expect(buckets[0].id == "gemini")
        #expect(buckets[0].remainingPercent == 78)
        #expect(buckets[0].modelClasses == [.neon])
    }

    @Test("Parses go-keyring-base64 Keychain payload with microsecond expiry and id_token_email")
    func parseGoKeyringKeychainPayload() throws {
        let jsonStr = """
        {
          "token": {
            "access_token": "ya29.test-access-token-123",
            "token_type": "Bearer",
            "refresh_token": "1//test-refresh",
            "expiry": "2026-11-17T13:43:16.104564+08:00",
            "expires_in": 3599
          },
          "auth_method": "oauth-personal",
          "id_token_email": "dev@example.com",
          "writer_id": "agy-cli"
        }
        """
        let raw = "go-keyring-base64:" + Data(jsonStr.utf8).base64EncodedString()
        let parsed = try #require(AGYQuotaParser.parseGoKeyringAuthPayload(raw))
        #expect(parsed.accessToken == "ya29.test-access-token-123")
        #expect(parsed.email == "dev@example.com")
        let expectedExpiry = try #require(AppDate.parseISO8601("2026-11-17T13:43:16.104564+08:00"))
        #expect(parsed.expiry == expectedExpiry)

        // Hex-encoded output from `/usr/bin/security -w` is also decoded transparently
        let hexRaw = raw.utf8.map { String(format: "%02x", $0) }.joined()
        let parsedHex = try #require(AGYQuotaParser.parseGoKeyringAuthPayload(hexRaw))
        #expect(parsedHex.accessToken == "ya29.test-access-token-123")
        #expect(parsedHex.email == "dev@example.com")
    }

    @Test("Ignores chat_* / tab_* internal entries and merges fetchAvailableModels + retrieveUserQuotaSummary")
    func mergeLiveQuotaModelsAndSummary() {
        let availableModelsJSON = """
        {
          "models": {
            "chat_20706": { "quotaInfo": { "remainingFraction": 1 } },
            "tab_flash_lite_preview": { "quotaInfo": { "remainingFraction": 1 } },
            "gemini-3-flash": {
              "displayName": "Gemini 3 Flash",
              "quotaInfo": { "remainingFraction": 0.32306847, "resetTime": "2026-11-17T04:53:55Z" }
            },
            "gemini-4-carbon-medium": {
              "displayName": "Gemini 4 Carbon (Medium)",
              "quotaInfo": { "remainingFraction": 0.36, "resetTime": "2026-11-17T04:53:55Z" }
            },
            "claude-opus-5-5-high": {
              "displayName": "Claude Opus 5.5 (High)",
              "quotaInfo": { "remainingFraction": 1, "resetTime": "2026-11-17T09:52:28Z" }
            }
          }
        }
        """

        let onlyModels = AGYQuotaParser.parseAvailableModelsJSON(Data(availableModelsJSON.utf8))
        #expect(onlyModels.count == 2)
        #expect(onlyModels[0].id == "gemini")
        #expect(onlyModels[0].remainingPercent == 32)
        #expect(onlyModels[1].id == "claude_partner")
        #expect(onlyModels[1].remainingPercent == 100)

        let summaryJSON = """
        {
          "groups": [
            {
              "displayName": "Claude and GPT models",
              "description": "Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B",
              "buckets": [
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "resetTime": "2026-11-24T04:52:30Z",
                  "remainingFraction": 0.85
                },
                {
                  "bucketId": "3p-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "resetTime": "2026-11-17T09:52:30Z",
                  "remainingFraction": 0.92
                }
              ]
            }
          ]
        }
        """

        let merged = AGYQuotaParser.mergeLiveQuotaBuckets(
            availableModelsData: Data(availableModelsJSON.utf8),
            quotaSummaryData: Data(summaryJSON.utf8)
        )
        #expect(merged.count == 3)
        #expect(merged[0].id == "gemini")
        #expect(merged[0].remainingPercent == 32)
        #expect(merged[1].id == "claude_partner")
        #expect(merged[1].remainingPercent == 92)
        #expect(merged[2].id == "claude_partner_weekly")
        #expect(merged[2].remainingPercent == 85)
    }

    @Test("Parses AICode fetchQuotaStatus quotaSummary.groups including gemini-weekly and gemini-5h")
    func parseAICodeFetchQuotaStatus() {
        let aicodeJSON = """
        {
          "buckets": [
            {
              "remainingFraction": 1,
              "resetTime": "2026-11-17T10:17:48Z",
              "model": { "modelId": "claude-opus-5-5", "displayName": "Claude Opus 5.5" }
            },
            {
              "remainingFraction": 1,
              "resetTime": "2026-11-17T10:17:48Z",
              "model": { "modelId": "gemini-3.8-flash", "displayName": "Gemini 3.8 Flash" }
            }
          ],
          "quotaSummary": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "description": "Models within this group: Gemini Flash, Gemini Pro",
                "buckets": [
                  {
                    "bucketId": "gemini-weekly",
                    "displayName": "Weekly Limit Remaining",
                    "refreshWindowLabel": "weekly",
                    "remainingFraction": 0.5893855,
                    "resetTime": "2026-11-23T08:53:55Z"
                  },
                  {
                    "bucketId": "gemini-5h",
                    "displayName": "Five Hour Limit Remaining",
                    "refreshWindowLabel": "5h",
                    "remainingFraction": 0.9145569,
                    "resetTime": "2026-11-17T09:53:55Z"
                  }
                ]
              },
              {
                "displayName": "Claude and GPT models",
                "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
                "buckets": [
                  {
                    "bucketId": "3p-weekly",
                    "displayName": "Weekly Limit Remaining",
                    "refreshWindowLabel": "weekly",
                    "remainingFraction": 1,
                    "resetTime": "2026-11-24T05:17:48Z"
                  },
                  {
                    "bucketId": "3p-5h",
                    "displayName": "Five Hour Limit Remaining",
                    "refreshWindowLabel": "5h",
                    "remainingFraction": 1,
                    "resetTime": "2026-11-17T10:17:48Z"
                  }
                ]
              }
            ]
          }
        }
        """

        let buckets = AGYQuotaParser.mergeLiveQuotaBuckets(
            availableModelsData: nil,
            quotaSummaryData: nil,
            aicodeQuotaData: Data(aicodeJSON.utf8)
        )
        #expect(buckets.count == 4)
        #expect(buckets[0].id == "gemini")
        #expect(buckets[0].remainingPercent == 91)
        #expect(buckets[0].usedPercent == 9)
        #expect(buckets[1].id == "gemini_weekly")
        #expect(buckets[1].remainingPercent == 59)
        #expect(buckets[1].usedPercent == 41)
        #expect(buckets[1].resetAt != nil)
        #expect(buckets[2].id == "claude_partner")
        #expect(buckets[2].remainingPercent == 100)
        #expect(buckets[3].id == "claude_partner_weekly")
        #expect(buckets[3].remainingPercent == 100)
    }

    @Test("Decoupled AICode unused Gemini pool never clobbers consumed 5h or injects fake 100% gemini_weekly")
    func decoupledAICodeDoesNotClobberOrInjectFakeWeekly() throws {
        // Exact user bug reproduction:
        // - daily fetchAvailableModels reports Gemini at 87% remaining with 1h reset
        // - retrieveUserQuotaSummary returns 3P-only buckets with Claude & GPT at 26%
        // - decoupled aicode returns dummy 100% buckets with 5h/7d resets
        let availableModelsJSON = """
        {
          "models": {
            "gemini-4-carbon-medium": {
              "displayName": "Gemini 4 Carbon (Medium)",
              "quotaInfo": { "remainingFraction": 0.87, "resetTime": "2026-11-26T08:20:00Z" }
            },
            "claude-opus-5-5-high": {
              "displayName": "Claude Opus 5.5 (High)",
              "quotaInfo": { "remainingFraction": 0.26, "resetTime": "2026-11-26T10:00:00Z" }
            }
          }
        }
        """
        let summary3POnlyJSON = """
        {
          "groups": [
            {
              "displayName": "Claude and GPT models",
              "description": "Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B",
              "buckets": [
                {
                  "bucketId": "3p-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "remainingFraction": 0.26,
                  "resetTime": "2026-11-26T10:00:00Z"
                },
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "remainingFraction": 0.64,
                  "resetTime": "2026-12-03T07:00:00Z"
                }
              ]
            }
          ]
        }
        """
        let decoupledAICodeJSON = """
        {
          "quotaSummary": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {
                    "bucketId": "gemini-5h",
                    "displayName": "Five Hour Limit Remaining",
                    "refreshWindowLabel": "5h",
                    "remainingFraction": 1.0,
                    "resetTime": "2026-11-26T12:20:00Z"
                  },
                  {
                    "bucketId": "gemini-weekly",
                    "displayName": "Weekly Limit Remaining",
                    "refreshWindowLabel": "weekly",
                    "remainingFraction": 1.0,
                    "resetTime": "2026-12-03T07:20:00Z"
                  }
                ]
              },
              {
                "displayName": "Claude and GPT models",
                "buckets": [
                  {
                    "bucketId": "3p-5h",
                    "displayName": "Five Hour Limit Remaining",
                    "refreshWindowLabel": "5h",
                    "remainingFraction": 1.0,
                    "resetTime": "2026-11-26T12:20:00Z"
                  },
                  {
                    "bucketId": "3p-weekly",
                    "displayName": "Weekly Limit Remaining",
                    "refreshWindowLabel": "weekly",
                    "remainingFraction": 1.0,
                    "resetTime": "2026-12-03T07:20:00Z"
                  }
                ]
              }
            ]
          }
        }
        """

        let merged = AGYQuotaParser.mergeLiveQuotaBuckets(
            availableModelsData: Data(availableModelsJSON.utf8),
            quotaSummaryData: Data(summary3POnlyJSON.utf8),
            aicodeQuotaData: Data(decoupledAICodeJSON.utf8)
        )

        #expect(merged.count == 3)
        #expect(!AGYQuotaParser.hasGeminiWeeklyBucket(merged))
        #expect(merged.map(\.id) == ["gemini", "claude_partner", "claude_partner_weekly"])

        let expectedGeminiReset = try #require(AppDate.parseISO8601("2026-11-26T08:20:00Z"))
        #expect(merged[0].remainingPercent == 87)
        #expect(merged[0].resetAt == expectedGeminiReset)
        #expect(merged[1].remainingPercent == 26)
        #expect(merged[1].title == "Claude & GPT · 5h")
        #expect(merged[2].remainingPercent == 64)
    }

    @Test("Parses modern Hub retrieveUserQuotaSummary with all 4 standard buckets")
    func parseModernHubFourBucketSummary() throws {
        let hubSummaryJSON = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "description": "Models within this group: Gemini Flash, Gemini Pro",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "remainingFraction": 0.77,
                  "resetTime": "2026-12-01T02:27:57Z"
                },
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "remainingFraction": 0.87,
                  "resetTime": "2026-11-26T08:20:00Z"
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
              "buckets": [
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "remainingFraction": 0.52,
                  "resetTime": "2026-12-02T14:00:00Z"
                },
                {
                  "bucketId": "3p-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "remainingFraction": 0.26,
                  "resetTime": "2026-11-26T10:15:00Z"
                }
              ]
            }
          ]
        }
        """

        let buckets = AGYQuotaParser.parseAvailableModelsJSON(Data(hubSummaryJSON.utf8))
        #expect(buckets.count == 4)
        #expect(AGYQuotaParser.hasGeminiWeeklyBucket(buckets))
        #expect(buckets.map(\.id) == ["gemini", "gemini_weekly", "claude_partner", "claude_partner_weekly"])
        #expect(buckets[0].remainingPercent == 87)
        #expect(buckets[1].remainingPercent == 77)
        #expect(buckets[1].resetAt == AppDate.parseISO8601("2026-12-01T02:27:57Z"))
        #expect(buckets[2].remainingPercent == 26)
        #expect(buckets[3].remainingPercent == 52)
    }

    @Test("Parses agy -p /usage --output-format json including epoch sentinel filtering, rejections, and CLI fallback merge")
    func parseCLIUsageJSONAndFallbackMerge() throws {
        let cliUsageJSON = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "description": "Current plan usage summary",
              "groups": [
                {
                  "name": "Gemini Models",
                  "description": "Models within this group: Gemini 4 Carbon, Gemini 4 Neon, Gemini Flash",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.77,
                      "reset_time": "2026-12-01T02:27:57Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.87,
                      "reset_time": "1970-01-01T00:00:00Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 1.0,
                      "reset_time": "0001-01-01T00:00:00Z"
                    },
                    {
                      "id": "3p-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.91,
                      "reset_time": "2026-11-26T11:30:00Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let cliBuckets = AGYQuotaParser.parseCLIUsageJSON(Data(cliUsageJSON.utf8))
        #expect(cliBuckets.count == 4)
        #expect(AGYQuotaParser.hasGeminiWeeklyBucket(cliBuckets))
        #expect(cliBuckets[0].id == "gemini")
        #expect(cliBuckets[0].remainingPercent == 87)
        #expect(cliBuckets[0].resetAt == nil) // 1970-01-01T00:00:00Z treated as nil
        #expect(cliBuckets[1].id == "gemini_weekly")
        #expect(cliBuckets[1].remainingPercent == 77)
        #expect(cliBuckets[1].resetAt == AppDate.parseISO8601("2026-12-01T02:27:57Z"))
        #expect(cliBuckets[2].id == "claude_partner")
        #expect(cliBuckets[2].remainingPercent == 91)
        #expect(cliBuckets[3].id == "claude_partner_weekly")
        #expect(cliBuckets[3].resetAt == nil) // 0001-01-01T00:00:00Z treated as nil

        // Reject non-SUCCESS status and non-usage commands
        let errorStatusJSON = """
        { "status": "ERROR", "command": { "name": "usage", "data": { "groups": [{ "name": "Gemini Models", "buckets": [{ "id": "gemini-weekly", "remaining_fraction": 0.5 }] }] } } }
        """
        #expect(AGYQuotaParser.parseCLIUsageJSON(Data(errorStatusJSON.utf8)).isEmpty)

        let wrongCommandJSON = """
        { "status": "SUCCESS", "command": { "name": "models", "data": { "groups": [{ "name": "Gemini Models", "buckets": [{ "id": "gemini-weekly", "remaining_fraction": 0.5 }] }] } } }
        """
        #expect(AGYQuotaParser.parseCLIUsageJSON(Data(wrongCommandJSON.utf8)).isEmpty)

        // Merge with fetchAvailableModels (which has a real resetTime for gemini 5h) + CLI fallback
        let modelsJSON = """
        {
          "models": {
            "gemini-4-carbon-medium": {
              "displayName": "Gemini 4 Carbon (Medium)",
              "quotaInfo": { "remainingFraction": 0.87, "resetTime": "2026-11-26T08:20:00Z" }
            }
          }
        }
        """
        let merged = AGYQuotaParser.mergeLiveQuotaBuckets(
            availableModelsData: Data(modelsJSON.utf8),
            quotaSummaryData: nil,
            aicodeQuotaData: nil,
            cliUsageData: Data(cliUsageJSON.utf8)
        )
        #expect(merged.count == 4)
        #expect(AGYQuotaParser.hasGeminiWeeklyBucket(merged))
        let expectedGeminiReset = try #require(AppDate.parseISO8601("2026-11-26T08:20:00Z"))
        // Tied remainingFraction (0.87): valid non-nil resetAt from models wins over nil epoch reset from CLI
        #expect(merged[0].id == "gemini")
        #expect(merged[0].remainingPercent == 87)
        #expect(merged[0].resetAt == expectedGeminiReset)
        #expect(merged[1].id == "gemini_weekly")
        #expect(merged[1].remainingPercent == 77)
    }

    @Test("Preserves distinct Gemini sub-tier buckets (gemini-argon-wtu-weekly) alongside gemini-weekly and deduplicates safely")
    func distinctGeminiSubTierAndSafeDedup() throws {
        let cliJSON = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.90,
                      "reset_time": "2026-12-01T08:00:00Z"
                    },
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.77,
                      "reset_time": "2026-12-01T02:27:57Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.85,
                      "reset_time": "2026-11-26T10:00:00Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.85,
                      "reset_time": "2026-11-26T09:00:00Z"
                    }
                  ]
                },
                {
                  "name": "Gemini Argon WTU",
                  "description": "Models within this group: Gemini 4 Argon",
                  "buckets": [
                    {
                      "id": "gemini-argon-wtu-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.42,
                      "reset_time": "2026-12-01T04:00:00Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let buckets = AGYQuotaParser.parseCLIUsageJSON(Data(cliJSON.utf8))
        #expect(buckets.count == 3)
        #expect(AGYQuotaParser.hasGeminiWeeklyBucket(buckets))
        #expect(buckets.map(\.id) == ["gemini", "gemini_weekly", "gemini_argon_wtu_weekly"])

        // Tied remainingFraction on gemini-5h deduplicates to earlier resetAt
        #expect(buckets[0].remainingPercent == 85)
        #expect(buckets[0].resetAt == AppDate.parseISO8601("2026-11-26T09:00:00Z"))

        // Duplicate gemini-weekly deduplicates to lower remainingFraction (0.77)
        #expect(buckets[1].remainingPercent == 77)
        #expect(buckets[1].resetAt == AppDate.parseISO8601("2026-12-01T02:27:57Z"))

        // Sub-tier bucket stays distinct and never clobbers gemini_weekly
        #expect(buckets[2].id == "gemini_argon_wtu_weekly")
        #expect(buckets[2].title == "Gemini Argon WTU")
        #expect(buckets[2].remainingPercent == 42)
        #expect(buckets[2].modelClasses == [.argon])
        #expect(buckets[2].resetAt == AppDate.parseISO8601("2026-12-01T04:00:00Z"))

        // A sub-tier bucket alone does NOT satisfy hasGeminiWeeklyBucket
        #expect(!AGYQuotaParser.hasGeminiWeeklyBucket([buckets[2]]))
    }

    @Test("Handles proto3/Go omitempty zero exhaustion and skips empty sentinel summary buckets")
    func proto3ZeroExhaustionAndEmptySummaryBucketSkipping() throws {
        let cliJSON = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0,
                      "reset_time": "2026-11-26T10:00:00Z"
                    },
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "reset_time": "2026-12-01T02:27:57Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {
                      "id": "3p-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "reset_time": "1970-01-01T00:00:00Z"
                    },
                    {
                      "id": "3p-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": true
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let buckets = AGYQuotaParser.parseCLIUsageJSON(Data(cliJSON.utf8))
        #expect(buckets.count == 2)
        #expect(buckets.map(\.id) == ["gemini", "gemini_weekly"])

        // Explicit 0 -> 0% remaining
        #expect(buckets[0].remainingPercent == 0)
        #expect(buckets[0].usedPercent == 100)
        #expect(buckets[0].resetAt == AppDate.parseISO8601("2026-11-26T10:00:00Z"))

        // Omitted remaining_fraction with valid future reset_time -> 0% remaining (exhausted)
        #expect(buckets[1].remainingPercent == 0)
        #expect(buckets[1].usedPercent == 100)
        #expect(buckets[1].resetAt == AppDate.parseISO8601("2026-12-01T02:27:57Z"))
        // 3p-5h (omitted fraction + sentinel reset) and 3p-weekly (Bool fraction + missing reset) are skipped
    }

    @Test("Nested gemini-argon-wtu-weekly inside Gemini Models group keeps distinct Argon title and class despite Hydrogen in group description")
    func nestedArgonSubTierInsideGenericGeminiModelsGroup() {
        let cliJSON = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "description": "Models within this group: Gemini 4 Hydrogen, Gemini 4 Argon, Gemini 4 Carbon",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.77,
                      "reset_time": "2026-12-01T02:27:57Z"
                    },
                    {
                      "id": "gemini-argon-wtu-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.55,
                      "reset_time": "2026-12-01T02:27:57Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let buckets = AGYQuotaParser.parseCLIUsageJSON(Data(cliJSON.utf8))
        #expect(buckets.count == 2)
        #expect(buckets[0].id == "gemini_weekly")
        #expect(buckets[1].id == "gemini_argon_wtu_weekly")
        #expect(buckets[1].title == "Gemini Argon WTU · Weekly")
        #expect(buckets[1].modelClasses == [.argon])
        #expect(ModelClass.classify(buckets[1].title) == .argon)
    }

    @Test("Merge preserves valid resetAt from losing bucket when lower-fraction winner has nil resetAt")
    func mergePreservesValidResetAtWhenWinnerResetIsNil() throws {
        let modelsJSON = """
        {
          "models": {
            "gemini-4-carbon-medium": {
              "displayName": "Gemini 4 Carbon (Medium)",
              "quotaInfo": { "remainingFraction": 0.87, "resetTime": "2026-11-26T08:20:00Z" }
            }
          }
        }
        """
        let cliJSON = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.85,
                      "reset_time": "1970-01-01T00:00:00Z"
                    },
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.77,
                      "reset_time": "2026-12-01T02:27:57Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let merged = AGYQuotaParser.mergeLiveQuotaBuckets(
            availableModelsData: Data(modelsJSON.utf8),
            quotaSummaryData: nil,
            aicodeQuotaData: nil,
            cliUsageData: Data(cliJSON.utf8)
        )
        #expect(merged.count == 2)
        let expectedReset = try #require(AppDate.parseISO8601("2026-11-26T08:20:00Z"))
        // CLI's lower remainingFraction (0.85) wins, while models' valid resetAt is preserved
        #expect(merged[0].id == "gemini")
        #expect(merged[0].remainingPercent == 85)
        #expect(merged[0].resetAt == expectedReset)
        #expect(merged[1].id == "gemini_weekly")
        #expect(merged[1].remainingPercent == 77)
    }

    @Test("Unused 100% summary bucket with nil reset wins over fetchAvailableModels synthetic rolling reset")
    func unusedSummaryNilResetBeatsSyntheticModelReset() {
        let modelsJSON = """
        {
          "models": {
            "claude-opus-5-5-high": {
              "displayName": "Claude Opus 5.5 (High)",
              "quotaInfo": { "remainingFraction": 1.0, "resetTime": "2026-11-26T12:42:28Z" }
            }
          }
        }
        """
        let summaryJSON = """
        {
          "groups": [
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "remainingFraction": 1.0,
                  "resetTime": "1970-01-01T00:00:00Z"
                },
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "remainingFraction": 0.26,
                  "resetTime": "2026-11-30T00:52:12Z"
                }
              ]
            }
          ]
        }
        """

        let merged = AGYQuotaParser.mergeLiveQuotaBuckets(
            availableModelsData: Data(modelsJSON.utf8),
            quotaSummaryData: Data(summaryJSON.utf8)
        )
        #expect(merged.count == 2)
        #expect(merged[0].id == "claude_partner")
        #expect(merged[0].title == "Claude & GPT · 5h")
        #expect(merged[0].remainingPercent == 100)
        #expect(merged[0].resetAt == nil)
        #expect(merged[1].id == "claude_partner_weekly")
        #expect(merged[1].remainingPercent == 26)
        #expect(merged[1].resetAt == AppDate.parseISO8601("2026-11-30T00:52:12Z"))
    }
}
