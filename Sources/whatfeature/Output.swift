import ArgumentParser
import Foundation
import WhatFeatureAPI
import WhatFeatureCore
import WhatFeatureStorage

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print JSON instead of a summary.")
    var json = false
}

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// Columns padded to the widest value. The last column isn't padded.
func printTable(_ headers: [String], _ rows: [[String]]) {
    let all = [headers] + rows
    let widths = headers.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
    for row in all {
        let cells = row.enumerated().map { index, cell in
            index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }
        print(cells.joined(separator: "  "))
    }
}

func format(_ date: Date) -> String {
    date.formatted(.iso8601)
}

func compactJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "?"
}

// MARK: - Flags and configs

func printFlags(_ flags: [WhatFeatureCore.Flag]) {
    if flags.isEmpty {
        print("No flags.")
        return
    }
    printTable(
        ["KEY", "TYPE", "CREATED", "STATE", "DESCRIPTION"],
        flags.map { [$0.key, $0.type.rawValue, format($0.createdAt), $0.isArchived ? "archived" : "", $0.description] }
    )
}

func printFlagDetail(_ detail: FlagDetail) {
    let flag = detail.flag
    var title = "\(flag.key) (\(flag.type.rawValue))"
    if flag.isExperiment { title += " · experiment" }
    if flag.isArchived { title += " · archived" }
    print(title)
    if !flag.description.isEmpty { print(flag.description) }
    print("Variants: " + flag.variants.sorted { $0.key < $1.key }.map { "\($0.key)=\(compactJSON($0.value))" }.joined(separator: ", "))
    print("Created \(format(flag.createdAt)) by \(flag.createdBy)")
    print("")
    printTable(
        ["ENVIRONMENT", "STATE", "VERSION", "BEHAVIOR"],
        detail.configs.sorted { $0.key < $1.key }.map { environment, config in
            [environment, config.enabled ? "enabled" : "disabled", "v\(config.version)", summary(of: config)]
        }
    )
}

/// One line, e.g. "2 rules, then 10% on / 90% off".
func summary(of config: FlagConfig) -> String {
    let rules = switch config.rules.count {
    case 0: ""
    case 1: "1 rule, then "
    case let count: "\(count) rules, then "
    }
    return rules + summary(of: config.defaultResult)
}

func summary(of result: RuleResult) -> String {
    switch result {
    case .variant(let variant):
        return variant
    case .rollout(let rollout):
        return rollout.map { "\(percent($0.weight)) \($0.variant)" }.joined(separator: " / ")
    }
}

/// 1000 → "10%", 1250 → "12.5%".
func percent(_ weight: Int) -> String {
    let value = Double(weight) / Double(Bucketing.bucketCount) * 100
    return value.formatted(.number.precision(.fractionLength(0...2))) + "%"
}

func printConfig(_ config: FlagConfig, environment: String, flag: String) throws {
    print("\(flag) in \(environment): \(config.enabled ? "enabled" : "disabled"), v\(config.version)")
    print("")
    try printJSON(config)
}

// MARK: - Tokens

func printTokens(_ tokens: [Token]) {
    if tokens.isEmpty {
        print("No tokens.")
        return
    }
    printTable(
        ["ID", "KIND", "STATE", "LAST USED", "NAME"],
        tokens.map { token in
            [
                token.id.rawValue, token.kind.rawValue, token.isRevoked ? "revoked" : "active",
                token.lastUsedAt.map(format) ?? "never", token.name,
            ]
        }
    )
}

func printCreatedToken(_ token: Token, secret: String) {
    print("""
    Created \(token.kind.rawValue) token \(token.id) ("\(token.name)").
    Secret (save it now; it won't be shown again):

        \(secret)
    """)
}

// MARK: - Dry runs

/// The JSON exactly as the server sends it: sorted keys, compact.
func appJSONString(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "?"
}

func printDryRun(_ result: DryRunResult) {
    if let value = result.value, let variant = result.variant {
        let why = result.matchedRule.map { "rule \($0)" } ?? "the default"
        print("\(variant) = \(compactJSON(value))")
        print("Reason: \(result.reason.rawValue), from \(why) (config v\(result.configVersion))")
    } else if let code = result.errorCode {
        print("Error: \(code.rawValue): \(result.errorDetails ?? "")")
        print("Apps would use their own default.")
    } else {
        print("Disabled: apps use their own default. (config v\(result.configVersion))")
    }
    print("App gets (HTTP \(result.ofrep.status)): \(appJSONString(result.ofrep.body))")
}

func printDryRuns(_ results: [DryRunResult]) {
    if results.isEmpty {
        print("No flags.")
        return
    }
    printTable(
        ["FLAG", "RESULT", "REASON", "WHY"],
        results.map { result in
            if let value = result.value, let variant = result.variant {
                let why = result.matchedRule.map { "rule \($0)" } ?? "default"
                return [result.key, "\(variant) = \(compactJSON(value))", result.reason.rawValue, "\(why), config v\(result.configVersion)"]
            } else if let code = result.errorCode {
                return [result.key, "error", code.rawValue, result.errorDetails ?? ""]
            } else {
                return [result.key, "disabled", result.reason.rawValue, "app uses its own default"]
            }
        }
    )
    print("")
    print("--app-json shows exactly what an app gets.")
}
