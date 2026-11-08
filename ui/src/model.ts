import type { Condition, FlagConfig, FlagType, JSONValue, Operator, RuleResult } from './api'

// Pure helpers for flags, rules and values. No Vue, no network, so they're easy to test.

/** What kind of operand an operator takes, which decides the input the editor shows. */
export type OperandKind = 'any' | 'list' | 'string' | 'number' | 'version' | 'none'

export const operatorGroups: { label: string; operators: { value: Operator; label: string; operand: OperandKind }[] }[] = [
  {
    label: 'Equality',
    operators: [
      { value: 'equals', label: 'equals', operand: 'any' },
      { value: 'notEquals', label: 'does not equal', operand: 'any' },
      { value: 'in', label: 'is one of', operand: 'list' },
      { value: 'notIn', label: 'is not one of', operand: 'list' },
    ],
  },
  {
    label: 'Strings',
    operators: [
      { value: 'startsWith', label: 'starts with', operand: 'string' },
      { value: 'endsWith', label: 'ends with', operand: 'string' },
      { value: 'contains', label: 'contains', operand: 'string' },
    ],
  },
  {
    label: 'Numbers',
    operators: [
      { value: 'eq', label: '=', operand: 'number' },
      { value: 'lt', label: '<', operand: 'number' },
      { value: 'lte', label: '≤', operand: 'number' },
      { value: 'gt', label: '>', operand: 'number' },
      { value: 'gte', label: '≥', operand: 'number' },
    ],
  },
  {
    label: 'Versions',
    operators: [
      { value: 'semverEq', label: 'version =', operand: 'version' },
      { value: 'semverLt', label: 'version <', operand: 'version' },
      { value: 'semverLte', label: 'version ≤', operand: 'version' },
      { value: 'semverGt', label: 'version >', operand: 'version' },
      { value: 'semverGte', label: 'version ≥', operand: 'version' },
    ],
  },
  {
    label: 'Presence',
    operators: [
      { value: 'exists', label: 'exists', operand: 'none' },
      { value: 'notExists', label: 'does not exist', operand: 'none' },
    ],
  },
]

const operators = new Map(operatorGroups.flatMap((group) => group.operators.map((op) => [op.value, op])))

export function operandKind(operator: Operator): OperandKind {
  return operators.get(operator)?.operand ?? 'any'
}

export function operatorLabel(operator: Operator): string {
  return operators.get(operator)?.label ?? operator
}

/**
 * The condition with `operator`, keeping as much of the old value as fits: `equals "US"` becomes `in ["US"]`,
 * and `in ["US", "CA"]` becomes `equals "US"`. What can't be kept becomes an empty value of the right kind.
 */
export function withOperator(condition: Condition, operator: Operator): Condition {
  const old = condition.value
  const first = Array.isArray(old) ? old[0] : old
  const text = typeof first === 'string' ? first : typeof first === 'number' ? String(first) : ''
  const next: Condition = { attribute: condition.attribute, operator }
  switch (operandKind(operator)) {
    case 'any':
      next.value = first === undefined || first === null ? '' : first
      break
    case 'list':
      next.value = Array.isArray(old) ? old : old === undefined || old === null || old === '' ? [] : [old]
      break
    case 'string':
    case 'version':
      next.value = text
      break
    case 'number': {
      const number = typeof first === 'number' ? first : Number.parseFloat(text)
      next.value = Number.isFinite(number) ? number : 0
      break
    }
    case 'none':
      break
  }
  return next
}

/** How the editor shows a scalar condition value: as text, a number, a boolean, or raw JSON. */
export type ScalarType = 'text' | 'number' | 'boolean' | 'json'

export function scalarType(value: JSONValue | undefined): ScalarType {
  switch (typeof value) {
    case 'number':
      return 'number'
    case 'boolean':
      return 'boolean'
    case 'string':
    case 'undefined':
      return 'text'
    default:
      return 'json'
  }
}

/**
 * Reads what was typed as a value of `type`. Throws a readable message if it doesn't parse.
 * Text stays text, even "2.0": otherwise app versions would become numbers and stop matching (as in the CLI).
 */
export function parseScalar(text: string, type: ScalarType): JSONValue {
  switch (type) {
    case 'text':
      return text
    case 'number': {
      const number = Number(text)
      if (text.trim() === '' || !Number.isFinite(number)) throw new Error(`'${text}' is not a number`)
      return number
    }
    case 'boolean':
      if (text !== 'true' && text !== 'false') throw new Error(`'${text}' is not true or false`)
      return text === 'true'
    case 'json':
      try {
        return JSON.parse(text) as JSONValue
      } catch {
        throw new Error(`'${text}' is not valid JSON`)
      }
  }
}

export function formatScalar(value: JSONValue | undefined, type: ScalarType): string {
  if (value === undefined) return ''
  if (type === 'json') return JSON.stringify(value)
  return String(value)
}

/** A variant value as it reads in a list: strings quoted, objects as compact JSON. */
export function formatValue(value: JSONValue | undefined): string {
  return value === undefined ? '—' : JSON.stringify(value)
}

/** A value in a table cell: strings as they are, anything else as JSON. */
export function plainValue(value: JSONValue | undefined): string {
  return typeof value === 'string' ? value : formatValue(value)
}

/** A value for a new variant of a flag type. */
export function emptyVariantValue(type: FlagType): JSONValue {
  switch (type) {
    case 'boolean':
      return false
    case 'string':
      return ''
    case 'number':
      return 0
    case 'object':
      return {}
  }
}

/** Starting variants for a new flag. */
export function defaultVariants(type: FlagType): [string, JSONValue][] {
  switch (type) {
    case 'boolean':
      return [['on', true], ['off', false]]
    case 'string':
      return [['control', ''], ['test', '']]
    case 'number':
      return [['low', 0], ['high', 1]]
    case 'object':
      return [['default', {}]]
  }
}

/** Weights are out of 10,000. "12.5%" for 1,250. */
export function percent(weight: number): string {
  return `${Number((weight / 100).toFixed(2))}%`
}

export const totalWeight = 10_000

/**
 * Splits 10,000 as evenly as whole weights allow, the remainder going to the first variants, so it always adds up.
 */
export function evenWeights(count: number): number[] {
  if (count <= 0) return []
  const base = Math.floor(totalWeight / count)
  const extra = totalWeight - base * count
  return Array.from({ length: count }, (_, index) => base + (index < extra ? 1 : 0))
}

export function describeResult(result: RuleResult): string {
  if ('variant' in result) return result.variant
  return result.rollout.map((entry) => `${entry.variant} ${percent(entry.weight)}`).join(' · ')
}

/** A one-line summary of a config for lists: "on", "2 rules, else off", "on 10% · off 90%". */
export function describeConfig(config: FlagConfig): string {
  const result = describeResult(config.defaultResult)
  if (config.rules.length === 0) return result
  return `${config.rules.length} rule${config.rules.length === 1 ? '' : 's'}, else ${result}`
}

/** Variants a result refers to. */
export function variantsIn(result: RuleResult): string[] {
  return 'variant' in result ? [result.variant] : result.rollout.map((entry) => entry.variant)
}

/** The config without `version`, as `PUT` takes it. */
export function configBody(config: FlagConfig): Omit<FlagConfig, 'version'> {
  const { version: _, ...body } = config
  return body
}

export interface DiffLine {
  kind: 'same' | 'add' | 'remove'
  text: string
}

/** A line diff (longest common subsequence), for an audit entry's before and after. */
export function lineDiff(before: string[], after: string[]): DiffLine[] {
  // common[i][j]: length of the longest common subsequence of before[i...] and after[j...].
  const common = Array.from({ length: before.length + 1 }, () => new Array<number>(after.length + 1).fill(0))
  for (let i = before.length - 1; i >= 0; i--) {
    for (let j = after.length - 1; j >= 0; j--) {
      common[i]![j] = before[i] === after[j] ? common[i + 1]![j + 1]! + 1 : Math.max(common[i + 1]![j]!, common[i]![j + 1]!)
    }
  }
  const lines: DiffLine[] = []
  let i = 0
  let j = 0
  while (i < before.length || j < after.length) {
    if (i < before.length && j < after.length && before[i] === after[j]) {
      lines.push({ kind: 'same', text: before[i++]! })
      j++
    } else if (i < before.length && (j === after.length || common[i + 1]![j]! >= common[i]![j + 1]!)) {
      // Removals before additions, as diffs usually read.
      lines.push({ kind: 'remove', text: before[i++]! })
    } else {
      lines.push({ kind: 'add', text: after[j++]! })
    }
  }
  return lines
}

/** Pretty JSON lines with keys sorted, so equal objects print the same way. */
export function jsonLines(value: unknown): string[] {
  if (value === undefined) return []
  const sorted = (item: unknown): unknown =>
    Array.isArray(item)
      ? item.map(sorted)
      : item !== null && typeof item === 'object'
        ? Object.fromEntries(Object.keys(item).sort().map((key) => [key, sorted((item as Record<string, unknown>)[key])]))
        : item
  return JSON.stringify(sorted(value), null, 2).split('\n')
}

export function clone<T>(value: T): T {
  return structuredClone(value)
}

/** Equal as JSON: for "has this draft changed?". */
export function sameJSON(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b)
}
