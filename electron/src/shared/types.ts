export type UsageSeverity = 'normal' | 'warning' | 'critical'
export interface UsageWindow {
  id: string
  label: string
  usedPercent: number
  resetsAt: number | null
  durationMinutes: number | null
  severity: UsageSeverity
}
export interface UsageSnapshot {
  email: string | null
  plan: string | null
  windows: UsageWindow[]
  credits: { balance: string | null; unlimited: boolean; hasCredits: boolean } | null
  fetchedAt: number
}
export type UsageStatus = 'loading' | 'ready' | 'cached' | 'signed-out' | 'unavailable' | 'api-key'
export interface UsageState {
  status: UsageStatus
  snapshot: UsageSnapshot | null
  refreshing: boolean
  message: string | null
  nextRefreshAt: number
  codexHome: string
  executable: string | null
}
export interface AgentCordAPI {
  getUsage(): Promise<UsageState>
  refreshUsage(): Promise<UsageState>
  onUsage(callback: (state: UsageState) => void): () => void
  onWindowShown(callback: () => void): () => void
  resizeWindow(height: number): Promise<void>
  hideWindow(): Promise<void>
  quit(): Promise<void>
}
