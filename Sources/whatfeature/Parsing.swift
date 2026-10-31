import ArgumentParser
import Foundation
import WhatFeatureServer
import WhatFeatureCore

/// Splits `name=value` at the first `=`.
func splitAssignment(_ text: String, what: String) throws -> (name: String, value: String) {
    guard let equals = text.firstIndex(of: "="), equals != text.startIndex else {
        throw ValidationError("Expected \(what) as name=value, got '\(text)'.")
    }
    return (String(text[..<equals]), String(text[text.index(after: equals)...]))
}

func parseJSON(_ text: String, what: String) throws -> JSONValue {
    do {
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    } catch {
        throw ValidationError("\(what) isn't valid JSON: \(text)")
    }
}

/// Variant values are read according to the flag's type, so `on=true` is a boolean for a boolean flag
/// and `greeting=Hello` needs no quotes for a string flag.
func parseVariants(_ assignments: [String], type: FlagType) throws -> [String: JSONValue] {
    var variants: [String: JSONValue] = [:]
    for assignment in assignments {
        let (name, text) = try splitAssignment(assignment, what: "a variant")
        let value: JSONValue
        switch type {
        case .boolean:
            guard let bool = Bool(text) else { throw ValidationError("Variant '\(name)' must be true or false.") }
            value = .bool(bool)
        case .string:
            value = .string(text)
        case .number:
            guard let number = Double(text) else { throw ValidationError("Variant '\(name)' must be a number.") }
            value = .number(number)
        case .object:
            value = try parseJSON(text, what: "Variant '\(name)'")
        }
        guard variants.updateValue(value, forKey: name) == nil else {
            throw ValidationError("Variant '\(name)' is listed twice.")
        }
    }
    return variants
}

/// `on=10 off=90` (percent, up to two decimals) → weights out of 10,000, in the order given.
func parseRollout(_ assignments: [String]) throws -> [WeightedVariant] {
    try assignments.map { assignment in
        let (variant, text) = try splitAssignment(assignment, what: "a rollout share")
        guard let percent = Decimal(string: text.hasSuffix("%") ? String(text.dropLast()) : text),
              percent >= 0, percent <= 100,
              (percent * 100).isWholeNumber
        else {
            throw ValidationError("'\(text)' isn't a percentage from 0 to 100 with at most two decimals.")
        }
        return WeightedVariant(variant: variant, weight: NSDecimalNumber(decimal: percent * 100).intValue)
    }
}

extension Decimal {
    var isWholeNumber: Bool {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return rounded == self
    }
}

/// Builds a context from `--context` (a JSON object), then `--targeting-key`, `--attr` (always a string) and
/// `--attr-json` (any JSON). Attributes are strings by default because values like app versions (`2.0`)
/// would otherwise turn into numbers and stop matching semver rules.
func buildContext(json: String?, targetingKey: String?, attributes: [String], jsonAttributes: [String]) throws -> EvaluationContext {
    var context = EvaluationContext()
    if let json {
        do {
            context = try JSONDecoder().decode(EvaluationContext.self, from: Data(json.utf8))
        } catch {
            throw ValidationError("--context must be a JSON object, like '{\"targetingKey\": \"user-1\"}'.")
        }
    }
    if let targetingKey { context.targetingKey = targetingKey }
    for assignment in attributes {
        let (name, value) = try splitAssignment(assignment, what: "an attribute")
        context.attributes[name] = .string(value)
    }
    for assignment in jsonAttributes {
        let (name, text) = try splitAssignment(assignment, what: "an attribute")
        context.attributes[name] = try parseJSON(text, what: "Attribute '\(name)'")
    }
    return context
}

/// Reads a whole file, or standard input for `-`.
func readInput(_ path: String) throws -> Data {
    if path == "-" {
        return FileHandle.standardInput.readDataToEndOfFile()
    }
    do {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw ValidationError("Couldn't read \(path): \(error.localizedDescription)")
    }
}

/// Asks on the terminal. Returns `false` when there's no terminal to ask on.
func confirm(_ question: String, expecting answer: String) -> Bool {
    guard isatty(STDIN_FILENO) != 0 else { return false }
    print(question, terminator: " ")
    return readLine()?.trimmingCharacters(in: .whitespaces) == answer
}

/// Requests per minute, or `off` for no limit.
func parseRateLimit(_ text: String, what: String) throws -> RateLimit? {
    if text.lowercased() == "off" { return nil }
    guard let perMinute = Int(text), perMinute > 0 else {
        throw ValidationError("\(what) must be a whole number of requests per minute, or 'off'. Got '\(text)'.")
    }
    return RateLimit(requestsPerMinute: perMinute)
}
