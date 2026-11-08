import { describe, expect, test } from 'vitest'
import { queryString } from './api'
import { evenWeights, lineDiff, parseScalar, withOperator } from './model'

describe('queryString', () => {
  test('encodes spaces as %20, since the server reads + as a plus', () => {
    expect(queryString({ targetingKey: 'device 42/x+y', limit: 5, flag: undefined, variant: '' })).toBe(
      '?targetingKey=device%2042%2Fx%2By&limit=5',
    )
    expect(queryString({})).toBe('')
  })
})

describe('parseScalar', () => {
  test('text stays text, even when it looks like a number', () => {
    expect(parseScalar('2.0', 'text')).toBe('2.0')
    expect(parseScalar('2.0', 'number')).toBe(2)
  })

  test('rejects what does not parse', () => {
    expect(() => parseScalar('', 'number')).toThrow()
    expect(() => parseScalar('yes', 'boolean')).toThrow()
    expect(() => parseScalar('{', 'json')).toThrow()
  })
})

describe('withOperator', () => {
  test('keeps the value when the kind of operand changes', () => {
    expect(withOperator({ attribute: 'country', operator: 'equals', value: 'US' }, 'in')).toEqual({
      attribute: 'country',
      operator: 'in',
      value: ['US'],
    })
    expect(withOperator({ attribute: 'country', operator: 'in', value: ['US', 'CA'] }, 'equals').value).toBe('US')
    expect(withOperator({ attribute: 'age', operator: 'equals', value: '18' }, 'gte').value).toBe(18)
  })

  test('drops the value for presence operators, and makes an empty one when nothing fits', () => {
    expect(withOperator({ attribute: 'email', operator: 'equals', value: 'x' }, 'exists')).toEqual({ attribute: 'email', operator: 'exists' })
    expect(withOperator({ attribute: 'email', operator: 'exists' }, 'in').value).toEqual([])
    expect(withOperator({ attribute: 'age', operator: 'equals', value: 'teen' }, 'lt').value).toBe(0)
  })
})

describe('evenWeights', () => {
  test('always adds up to 10,000, the remainder going first', () => {
    expect(evenWeights(3)).toEqual([3334, 3333, 3333])
    expect(evenWeights(7).reduce((a, b) => a + b, 0)).toBe(10_000)
    expect(evenWeights(0)).toEqual([])
  })
})

describe('lineDiff', () => {
  test('marks removed and added lines, removals first, and keeps the rest', () => {
    expect(lineDiff(['{', '  "a": 1', '  "b": 2', '}'], ['{', '  "a": 3', '  "b": 2', '  "c": 4', '}'])).toEqual([
      { kind: 'same', text: '{' },
      { kind: 'remove', text: '  "a": 1' },
      { kind: 'add', text: '  "a": 3' },
      { kind: 'same', text: '  "b": 2' },
      { kind: 'add', text: '  "c": 4' },
      { kind: 'same', text: '}' },
    ])
  })

  test('a create is all additions', () => {
    expect(lineDiff([], ['x', 'y']).map((line) => line.kind)).toEqual(['add', 'add'])
  })
})
