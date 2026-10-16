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
export type ProviderUsageState = Omit<UsageState, 'codexHome' | 'executable'>
export type ClaudeUsageState = ProviderUsageState
export type TokenProvider = 'claude' | 'cursor' | 'grok' | 'muse'
export type Agent = 'codex' | TokenProvider
/** Persisted in settings.json. The renderer only sees the agent and display options. */
export interface AppSettings {
  presenceEnabled: boolean
  agents: Record<Agent, boolean>
  unifiedUsage: boolean
  /** Launch at login was switched on once by default; never again after. */
  launchAtLoginDefaulted: boolean
}
export type UiSettings = Pick<AppSettings, 'agents' | 'unifiedUsage'>
export interface PresenceState {
  enabled: boolean
  // 'waiting' means enabled but Discord is not running or not connected yet.
  status: 'off' | 'waiting' | 'connected'
}
export interface LaunchAtLoginState {
  supported: boolean
  enabled: boolean
}
export interface AgentCordAPI {
  getUsage(): Promise<UsageState>
  refreshUsage(): Promise<UsageState>
  onUsage(callback: (state: UsageState) => void): () => void
  getProviderUsage(provider: TokenProvider): Promise<ProviderUsageState>
  refreshProviderUsage(provider: TokenProvider): Promise<ProviderUsageState>
  onProviderUsage(callback: (provider: TokenProvider, state: ProviderUsageState) => void): () => void
  getClaudeActive(): Promise<boolean>
  onClaudeActive(callback: (active: boolean) => void): () => void
  getPresence(): Promise<PresenceState>
  setPresenceEnabled(enabled: boolean): Promise<PresenceState>
  onPresence(callback: (state: PresenceState) => void): () => void
  onWindowShown(callback: () => void): () => void
  resizeWindow(height: number): Promise<void>
  getSettings(): Promise<UiSettings>
  setAgentEnabled(agent: Agent, enabled: boolean): Promise<UiSettings>
  setUnifiedUsage(enabled: boolean): Promise<UiSettings>
  getLaunchAtLogin(): Promise<LaunchAtLoginState>
  setLaunchAtLogin(enabled: boolean): Promise<LaunchAtLoginState>
  hideWindow(): Promise<void>
  quit(): Promise<void>
}
