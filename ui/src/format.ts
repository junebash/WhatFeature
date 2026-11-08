// Dates as people read them.

const relative = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' })
const absolute = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'medium' })

const units: [Intl.RelativeTimeFormatUnit, number][] = [
  ['year', 365 * 24 * 3600],
  ['month', 30 * 24 * 3600],
  ['week', 7 * 24 * 3600],
  ['day', 24 * 3600],
  ['hour', 3600],
  ['minute', 60],
  ['second', 1],
]

/** "3 minutes ago", "yesterday". */
export function timeAgo(iso: string, now = Date.now()): string {
  const seconds = (new Date(iso).getTime() - now) / 1000
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size || unit === 'second') {
      return Math.abs(seconds) < 10 ? 'just now' : relative.format(Math.round(seconds / size), unit)
    }
  }
  return iso
}

export function fullDate(iso: string): string {
  return absolute.format(new Date(iso))
}

/** A `<input type="datetime-local">` value (local time) as ISO 8601 with seconds, as the API wants. */
export function localInputToISO(value: string): string | undefined {
  if (!value) return undefined
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString().replace(/\.\d{3}Z$/, 'Z')
}
