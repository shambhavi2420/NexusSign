// Shared date parsing/formatting helpers for form fields.
//
// Why this exists: iOS Safari (JavaScriptCore) is far stricter than Chrome/V8
// about which date strings `new Date(string)` accepts. A stored value such as
// "2026 08 05" parses fine on desktop Chrome but yields an Invalid Date on
// iPad, which made date fields fall back to rendering the raw stored string
// (e.g. "2026 08 05" instead of "08/05/2026").
//
// Everything here parses date-only strings by hand so the result is identical
// on every browser. `new Date(string)` is only used as a last resort for
// non-numeric input such as "August 5, 2026".

const MONTH_NAMES_SHORT = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
]

const MONTH_NAMES_LONG = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
]

export const DEFAULT_DATE_FORMAT_US = 'MM/DD/YYYY'
export const DEFAULT_DATE_FORMAT = 'DD/MM/YYYY'

// Build a Date at local midnight. Returns null when the components don't form a
// real calendar date (e.g. 2026-02-31), so callers can fall back safely.
function buildLocalDate (year, month, day) {
  const y = parseInt(year, 10)
  const m = parseInt(month, 10)
  const d = parseInt(day, 10)

  if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) return null
  if (m < 1 || m > 12 || d < 1 || d > 31) return null

  const date = new Date(y, m - 1, d)

  // Reject overflowed dates (new Date(2026, 1, 31) silently rolls into March).
  if (date.getFullYear() !== y || date.getMonth() !== m - 1 || date.getDate() !== d) {
    return null
  }

  return date
}

// Resolve the browser locale. Safari can append Unicode extensions
// (e.g. "en-US-u-ca-gregory"), which breaks a naive endsWith('-US') check and
// made iPad and laptop disagree on the default format.
export function resolvedLocale () {
  try {
    return Intl.DateTimeFormat().resolvedOptions()?.locale || 'en-US'
  } catch {
    return 'en-US'
  }
}

export function defaultDateFormat (locale) {
  const base = String(locale || '').split('-u-')[0].toUpperCase()

  return base.endsWith('-US') ? DEFAULT_DATE_FORMAT_US : DEFAULT_DATE_FORMAT
}

// Parse a date value into a local-midnight Date, or null when unparseable.
export function parseDateLocal (value) {
  if (value === null || value === undefined || value === '') return null

  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : value
  }

  if (typeof value === 'number') {
    // Unix timestamp in seconds or milliseconds.
    const ms = String(Math.trunc(value)).length <= 10 ? value * 1000 : value
    const date = new Date(ms)

    return Number.isNaN(date.getTime()) ? null : date
  }

  const str = String(value).trim()

  if (!str) return null

  // ISO datetime: take the date portion so timezone never shifts the day.
  let match = str.match(/^(\d{4})-(\d{1,2})-(\d{1,2})[T\s]/)
  if (match) return buildLocalDate(match[1], match[2], match[3])

  // Year first: YYYY-MM-DD, YYYY/MM/DD, YYYY.MM.DD, "YYYY MM DD"
  match = str.match(/^(\d{4})[-/. ]+(\d{1,2})[-/. ]+(\d{1,2})$/)
  if (match) return buildLocalDate(match[1], match[2], match[3])

  // Day first, dot separated: DD.MM.YYYY
  match = str.match(/^(\d{1,2})\.+(\d{1,2})\.+(\d{4})$/)
  if (match) return buildLocalDate(match[3], match[2], match[1])

  // Month first: MM/DD/YYYY, MM-DD-YYYY, "MM DD YYYY"
  match = str.match(/^(\d{1,2})[-/ ]+(\d{1,2})[-/ ]+(\d{4})$/)
  if (match) return buildLocalDate(match[3], match[1], match[2])

  // Compact ISO: YYYYMMDD
  match = str.match(/^(\d{4})(\d{2})(\d{2})$/)
  if (match) return buildLocalDate(match[1], match[2], match[3])

  // Last resort for textual dates ("August 5, 2026"). Browser dependent, but
  // every numeric shape is already handled above.
  const parsed = new Date(str)

  return Number.isNaN(parsed.getTime()) ? null : parsed
}

function monthName (date, token, locale) {
  const style = token.length >= 4 ? 'long' : 'short'

  try {
    return new Intl.DateTimeFormat(locale || undefined, { month: style }).format(date)
  } catch {
    return style === 'long' ? MONTH_NAMES_LONG[date.getMonth()] : MONTH_NAMES_SHORT[date.getMonth()]
  }
}

function tokenValue (token, date, locale) {
  const upper = token.toUpperCase()

  if (upper.startsWith('D')) {
    const day = date.getDate()

    return token.length >= 2 ? String(day).padStart(2, '0') : String(day)
  }

  if (upper.startsWith('M')) {
    if (token.length >= 3) return monthName(date, token, locale)

    const month = date.getMonth() + 1

    return token.length === 2 ? String(month).padStart(2, '0') : String(month)
  }

  // Year
  const year = date.getFullYear()

  if (token.length === 2) return String(year).slice(-2).padStart(2, '0')

  return String(year)
}

// Format a date value using a token pattern (DD/MM/YYYY, MMM D, YYYY, ...).
// Falls back to the original value when it can't be parsed, so nothing is lost.
export function formatDateString (value, format, locale) {
  const date = parseDateLocal(value)

  if (!date) return value === null || value === undefined ? '' : String(value)

  const pattern = String(format || defaultDateFormat(locale || resolvedLocale()))

  // Single pass so substituted text is never re-scanned (e.g. the "D" in
  // "December" must not be treated as a day token).
  const formatted = pattern.replace(/D+|M+|Y+|d+|m+|y+/g, (token) => tokenValue(token, date, locale))

  return formatted
}

// Convert any supported value to YYYY-MM-DD, the only format an
// <input type="date"> accepts. Returns '' when unparseable.
export function toIsoDateString (value) {
  const str = String(value ?? '').trim()

  if (/^\d{4}-\d{2}-\d{2}$/.test(str)) return str

  const date = parseDateLocal(str)

  if (!date) return ''

  const yyyy = String(date.getFullYear()).padStart(4, '0')
  const mm = String(date.getMonth() + 1).padStart(2, '0')
  const dd = String(date.getDate()).padStart(2, '0')

  return `${yyyy}-${mm}-${dd}`
}

// Convert any supported value to MM/DD/YYYY, the shape date values are stored
// in. Returns the input unchanged when unparseable.
export function toUsDateString (value) {
  const date = parseDateLocal(value)

  if (!date) return value

  const mm = String(date.getMonth() + 1).padStart(2, '0')
  const dd = String(date.getDate()).padStart(2, '0')

  return `${mm}/${dd}/${date.getFullYear()}`
}

export function todayIsoDateString () {
  return toIsoDateString(new Date())
}
