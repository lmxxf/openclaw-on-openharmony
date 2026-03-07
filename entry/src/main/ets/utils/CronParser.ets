// Lightweight cron expression parser (5-field: min hour dom month dow)
// Supports: numbers, ranges (1-5), steps (*/5), lists (1,3,5), wildcards (*)

interface CronField {
  values: Set<number>
}

function parseField(field: string, min: number, max: number): CronField {
  const values = new Set<number>()
  const parts = field.split(',')

  for (const part of parts) {
    if (part === '*') {
      for (let i = min; i <= max; i++) values.add(i)
    } else if (part.includes('/')) {
      const segments = part.split('/')
      const step = parseInt(segments[1])
      let start = min
      if (segments[0] !== '*') {
        start = parseInt(segments[0])
      }
      for (let i = start; i <= max; i += step) values.add(i)
    } else if (part.includes('-')) {
      const segments = part.split('-')
      const rangeStart = parseInt(segments[0])
      const rangeEnd = parseInt(segments[1])
      for (let i = rangeStart; i <= rangeEnd; i++) values.add(i)
    } else {
      values.add(parseInt(part))
    }
  }

  return { values }
}

export function getNextCronTime(expression: string, after: Date): Date {
  const fields = expression.trim().split(/\s+/)
  if (fields.length !== 5) {
    throw new Error(`Invalid cron expression: ${expression}`)
  }

  const minute = parseField(fields[0], 0, 59)
  const hour = parseField(fields[1], 0, 23)
  const dom = parseField(fields[2], 1, 31)
  const month = parseField(fields[3], 1, 12)
  const dow = parseField(fields[4], 0, 6)

  // Start from next minute
  const next = new Date(after.getTime())
  next.setSeconds(0, 0)
  next.setMinutes(next.getMinutes() + 1)

  // Search up to 2 years ahead
  const maxIterations = 525960 // ~1 year in minutes
  for (let i = 0; i < maxIterations; i++) {
    const m = next.getMinutes()
    const h = next.getHours()
    const d = next.getDate()
    const mo = next.getMonth() + 1
    const w = next.getDay()

    if (month.values.has(mo) &&
        dom.values.has(d) &&
        dow.values.has(w) &&
        hour.values.has(h) &&
        minute.values.has(m)) {
      return next
    }

    next.setMinutes(next.getMinutes() + 1)
  }

  throw new Error(`No next run found for cron: ${expression}`)
}

export function computeNextRun(
  scheduleType: string,
  scheduleValue: string,
  currentNextRun: string | null
): string | null {
  if (scheduleType === 'once') return null

  const now = Date.now()

  if (scheduleType === 'cron') {
    const next = getNextCronTime(scheduleValue, new Date())
    return next.toISOString()
  }

  if (scheduleType === 'interval') {
    const ms = parseInt(scheduleValue)
    if (!ms || ms <= 0) {
      return new Date(now + 60000).toISOString()
    }
    let next = currentNextRun ? new Date(currentNextRun).getTime() + ms : now + ms
    while (next <= now) {
      next += ms
    }
    return new Date(next).toISOString()
  }

  return null
}
