import type { UsageWindow } from '../shared/types'

// Match windows/Format.cs and PopoverWindow.MaskedEmail.
export function ago(timestamp: number, now: number): string {
  const seconds = Math.max(0, Math.floor((now - timestamp) / 1000))
  if (seconds < 60) return 'just now'
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`
  return `${Math.floor(seconds / 86400)}d ago`
}
export function resetIn(timestamp: number, now: number): string {
  const remaining = timestamp - now
  const minutes = Math.floor(remaining / 60_000)
  if (minutes <= 0) return remaining > 0 ? '<1m' : 'now'
  const days = Math.floor(minutes / 1440)
  const hours = Math.floor(minutes / 60) % 24
  if (days > 0) return `${days}d ${hours}h`
  if (hours > 0) return `${hours}h ${minutes % 60}m`
  return `${minutes}m`
}
export function windowValue(window: UsageWindow, now: number): string {
  const percent = `${Math.round(window.usedPercent)}%`
  if (window.resetsAt === null) return percent
  const reset = resetIn(window.resetsAt, now)
  return `${percent} · ${reset === 'now' ? 'resets now' : reset}`
}
export function maskEmail(email: string): string {
  const at = email.indexOf('@')
  if (at < 0) return '•'.repeat(Math.max(email.length, 4))
  const local = email.slice(0, at)
  const domain = email.slice(at + 1)
  const maskedLocal = local
    ? local[0] + '•'.repeat(Math.max(3, local.length - 1))
    : '•••'
  const dot = domain.lastIndexOf('.')
  if (dot < 0) return `${maskedLocal}@${'•'.repeat(Math.max(3, domain.length))}`
  const name = domain.slice(0, dot)
  const maskedDomain = name
    ? name[0] + '•'.repeat(Math.max(2, name.length - 1))
    : '••'
  return `${maskedLocal}@${maskedDomain}${domain.slice(dot)}`
}
