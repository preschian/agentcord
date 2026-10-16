import { contextBridge, ipcRenderer } from 'electron'
import type {
  AgentCordAPI,
  PresenceState,
  ProviderUsageState,
  TokenProvider,
  UsageState,
} from '../shared/types'

const api: AgentCordAPI = {
  getUsage: () => ipcRenderer.invoke('usage:get'),
  refreshUsage: () => ipcRenderer.invoke('usage:refresh'),
  onUsage: (callback) => {
    const listener = (_event: Electron.IpcRendererEvent, state: UsageState) =>
      callback(state)
    ipcRenderer.on('usage:changed', listener)
    return () => ipcRenderer.removeListener('usage:changed', listener)
  },
  getProviderUsage: (provider) => ipcRenderer.invoke('provider:get', provider),
  refreshProviderUsage: (provider) => ipcRenderer.invoke('provider:refresh', provider),
  onProviderUsage: (callback) => {
    const listener = (
      _event: Electron.IpcRendererEvent,
      provider: TokenProvider,
      state: ProviderUsageState,
    ) => callback(provider, state)
    ipcRenderer.on('provider:changed', listener)
    return () => ipcRenderer.removeListener('provider:changed', listener)
  },
  getClaudeActive: () => ipcRenderer.invoke('claude-desktop:get'),
  onClaudeActive: (callback) => {
    const listener = (_event: Electron.IpcRendererEvent, active: boolean) =>
      callback(active)
    ipcRenderer.on('claude-desktop:changed', listener)
    return () => ipcRenderer.removeListener('claude-desktop:changed', listener)
  },
  getPresence: () => ipcRenderer.invoke('presence:get'),
  setPresenceEnabled: (enabled) => ipcRenderer.invoke('presence:set', enabled),
  onPresence: (callback) => {
    const listener = (_event: Electron.IpcRendererEvent, state: PresenceState) =>
      callback(state)
    ipcRenderer.on('presence:changed', listener)
    return () => ipcRenderer.removeListener('presence:changed', listener)
  },
  onWindowShown: (callback) => {
    const listener = () => callback()
    ipcRenderer.on('window:shown', listener)
    return () => ipcRenderer.removeListener('window:shown', listener)
  },
  resizeWindow: (height) => ipcRenderer.invoke('window:resize', height),
  getLaunchAtLogin: () => ipcRenderer.invoke('login-item:get'),
  setLaunchAtLogin: (enabled) => ipcRenderer.invoke('login-item:set', enabled),
  hideWindow: () => ipcRenderer.invoke('window:hide'),
  quit: () => ipcRenderer.invoke('app:quit'),
}
contextBridge.exposeInMainWorld('agentcord', Object.freeze(api))
