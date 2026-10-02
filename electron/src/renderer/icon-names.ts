// Google Material Symbols Rounded ligature names used throughout the UI.
export const materialSymbols = {
  arrow: 'chevron_right',
  settings: 'settings',
  eye: 'visibility',
  'eye-off': 'visibility_off',
  clock: 'schedule',
  refresh: 'refresh',
  hide: 'dock_to_right',
} as const

export type IconName = keyof typeof materialSymbols
