import type { UsageSnapshot, UsageWindow } from '../shared/types'

type ObjectValue = Record<string, unknown>
export function object(value: unknown): ObjectValue | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as ObjectValue : null
}
export function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value : null
}
function number(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}
function windowLabel(minutes: number | null, fallback: string): string {
  if (!minutes || minutes <= 0) return fallback
  if (minutes === 300) return '5-hour session'
  if (minutes === 10080) return 'Weekly limit'
  if (minutes % 1440 === 0) return `${minutes / 1440}-day limit`
  if (minutes % 60 === 0) return `${minutes / 60}-hour limit`
  return `${minutes}-minute limit`
}
function parseWindow(value: unknown, id: string, fallback: string, reached: boolean): UsageWindow | null {
  const raw = object(value)
  const percent = number(raw?.usedPercent)
  if (!raw || percent === null) return null // Missing data is not 0% usage.
  const usedPercent = Math.min(100, Math.max(0, percent))
  const reset = number(raw.resetsAt)
  const durationMinutes = number(raw.windowDurationMins)
  return {
    id, label: windowLabel(durationMinutes, fallback), usedPercent, durationMinutes,
    resetsAt: reset !== null && reset > 0 ? (reset < 1e12 ? reset * 1000 : reset) : null,
    severity: reached || usedPercent >= 90 ? 'critical' : usedPercent >= 70 ? 'warning' : 'normal',
  }
}
export function parseRateLimits(value: unknown): Pick<UsageSnapshot, 'plan' | 'windows' | 'credits'> {
  const result = object(value)
  const byId = object(result?.rateLimitsByLimitId)
  const limits = object(result?.rateLimits) ?? object(byId?.codex)
  const windows: UsageWindow[] = []
  const append = (snapshot: ObjectValue, id: string, name?: string) => {
    const reached = snapshot.rateLimitReachedType != null
    const primary = parseWindow(snapshot.primary, `${id}-primary`, 'Primary limit', reached)
    const secondary = parseWindow(snapshot.secondary, `${id}-secondary`, 'Secondary limit', false)
    for (const window of [primary, secondary]) {
      if (window) windows.push({ ...window, label: name ? `${name} · ${window.label}` : window.label })
    }
  }
  if (limits) append(limits, text(limits.limitId) ?? 'codex')
  for (const [id, value] of Object.entries(byId ?? {}).sort(([a], [b]) => a.localeCompare(b))) {
    if (id === 'codex' || id === text(limits?.limitId)) continue
    const scoped = object(value)
    if (!scoped) continue
    const name = (text(scoped.limitName) ?? text(scoped.limitId) ?? id).replace(/[_-]/g, ' ')
    append(scoped, id, name)
  }
  if (!windows.length) throw new Error('Codex has not returned valid subscription limit data.')
  const credits = object(limits?.credits)
  return {
    plan: text(limits?.planType), windows,
    credits: credits ? {
      balance: typeof credits.balance === 'number' ? String(credits.balance) : text(credits.balance),
      unlimited: credits.unlimited === true,
      hasCredits: credits.hasCredits === true,
    } : null,
  }
}
export function parseAccount(value: unknown): { type: string | null; email: string | null; plan: string | null } {
  const account = object(object(value)?.account)
  return { type: text(account?.type), email: text(account?.email), plan: text(account?.planType) }
}
