<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import type {
  Agent,
  PresenceState,
  LaunchAtLoginState,
  ProviderUsageState,
  TokenProvider,
  UiSettings,
  UsageState,
} from '../shared/types'
import Icon from './components/Icon.vue'
import UsageCard from './components/UsageCard.vue'
import { ago, maskEmail } from './format'

const logoUrl = `${import.meta.env.BASE_URL}agentcord.png`
const providers: Record<
  TokenProvider,
  { name: string; account: string; help: string; command: string }
> = {
  claude: {
    name: 'Claude',
    account: 'Anthropic / Claude',
    help: 'Sign in to Claude Code, then refresh.',
    command: 'claude /login',
  },
  cursor: {
    name: 'Cursor',
    account: 'Cursor',
    help: 'Sign in to Cursor or the Cursor CLI, then refresh.',
    command: 'cursor-agent login',
  },
  grok: {
    name: 'Grok',
    account: 'xAI / Grok',
    help: 'Sign in to the Grok CLI, then refresh.',
    command: 'grok login',
  },
  muse: {
    name: 'Muse Code',
    account: 'Meta / Muse Code',
    help: 'Sign in to Muse Code, then refresh.',
    command: 'muse login',
  },
}
const providerNames = Object.keys(providers) as TokenProvider[]
const agentNames: Agent[] = ['codex', ...providerNames]
const agentName = (agent: Agent) =>
  agent === 'codex' ? 'Codex' : providers[agent].name
const page = ref<'main' | 'codex' | TokenProvider | 'settings' | 'usage'>(
  'main',
)
const popover = ref<HTMLElement | null>(null)
const emailRevealed = ref(false)
const state = ref<UsageState>({
  status: 'loading',
  snapshot: null,
  refreshing: false,
  message: null,
  nextRefreshAt: 0,
  codexHome: '',
  executable: null,
})
const loading = (): ProviderUsageState => ({
  status: 'loading',
  snapshot: null,
  refreshing: false,
  message: null,
  nextRefreshAt: 0,
})
const providerStates = ref<Record<TokenProvider, ProviderUsageState>>({
  claude: loading(),
  cursor: loading(),
  grok: loading(),
  muse: loading(),
})
const claudeActive = ref(false)
const presence = ref<PresenceState>({ enabled: false, status: 'off' })
const presenceText = computed(
  () =>
    ({
      off: 'Off',
      waiting: 'Waiting for Discord',
      connected: 'Connected',
    })[presence.value.status],
)
const settings = ref<UiSettings>({
  agents: { codex: true, claude: true, cursor: true, grok: true, muse: true },
  unifiedUsage: true,
})
const enabledAgents = computed(() =>
  agentNames.filter((agent) => settings.value.agents[agent]),
)
const enabledProviders = computed(() =>
  providerNames.filter((name) => settings.value.agents[name]),
)
// One bar per enabled agent's primary window, like the Windows summary card.
const unifiedRows = computed(() =>
  enabledAgents.value.flatMap((agent) => {
    const primary = (agent === 'codex' ? state.value : providerStates.value[agent])
      .snapshot?.windows[0]
    return primary ? [{ agent, window: { ...primary, label: agentName(agent) } }] : []
  }),
)
const launchAtLogin = ref<LaunchAtLoginState>({ supported: false, enabled: false })
const launchBusy = ref(false)
const now = ref(Date.now())
const uiError = ref<string | null>(null)
const bridgeAvailable = ref(false)
let unsubscribe: (() => void) | undefined
let unsubscribeProviders: (() => void) | undefined
let unsubscribeClaudeActive: (() => void) | undefined
let unsubscribePresence: (() => void) | undefined
let unsubscribeWindowShown: (() => void) | undefined
let timer: ReturnType<typeof setInterval> | undefined
let observer: ResizeObserver | undefined
let lastHeight = 0
const tokenPage = computed(() =>
  providerNames.includes(page.value as TokenProvider)
    ? (page.value as TokenProvider)
    : null,
)
const meta = computed(() => (tokenPage.value ? providers[tokenPage.value] : null))
const providerName = computed(() => meta.value?.name ?? 'Codex')
const screenTitle = computed(() =>
  page.value === 'settings'
    ? 'Settings'
    : page.value === 'usage'
      ? 'Unified usage'
      : providerName.value,
)
// Detail screens read from whichever provider is open; Codex is the default.
const active = computed<ProviderUsageState>(() =>
  tokenPage.value ? providerStates.value[tokenPage.value] : state.value,
)
function rowStatus(value: ProviderUsageState) {
  return value.snapshot
    ? !value.snapshot.windows.length
      ? (value.snapshot.plan ?? 'Connected') // Signed in, no active window (Muse Code)
      : value.status === 'cached'
      ? 'Cached usage'
      : 'Connected'
    : value.status === 'loading'
      ? 'Connecting…'
      : 'Not connected'
}
const snapshot = computed(() => active.value.snapshot)
const cooldown = computed(() =>
  Math.max(0, Math.ceil((active.value.nextRefreshAt - now.value) / 1000)),
)
const statusText = computed(
  () =>
    ({
      loading: 'Connecting',
      ready: 'Connected',
      cached: 'Cached',
      'signed-out': 'Signed out',
      unavailable: 'Unavailable',
      'api-key': 'API key',
    })[state.value.status],
)
const updated = computed(() =>
  snapshot.value
    ? `Updated ${ago(snapshot.value.fetchedAt, now.value)}`
    : `Waiting for ${providerName.value} usage…`,
)
const accountLabel = computed(() => {
  const email = snapshot.value?.email
  return email
    ? emailRevealed.value
      ? email
      : maskEmail(email)
    : (meta.value?.account ?? 'OpenAI / ChatGPT')
})
const plan = computed(() => {
  const value = snapshot.value?.plan?.replace(/[_-]/g, ' ')
  return value ? value[0].toUpperCase() + value.slice(1) : null
})
const refreshLabel = computed(() =>
  active.value.refreshing
    ? 'Refreshing…'
    : cooldown.value
      ? `Refresh in ${cooldown.value}s`
      : 'Refresh usage',
)
const notice = computed(() => uiError.value ?? active.value.message)
function navigate(target: typeof page.value) {
  emailRevealed.value = false
  page.value = target
}
function applyState(value: UsageState) {
  if (value.snapshot?.email !== snapshot.value?.email)
    emailRevealed.value = false
  state.value = value
}
async function refresh() {
  uiError.value = null
  try {
    const name = tokenPage.value
    if (name)
      providerStates.value[name] =
        await window.agentcord.refreshProviderUsage(name)
    else applyState(await window.agentcord.refreshUsage())
  } catch {
    uiError.value =
      'The desktop connection was lost. Restart AgentCord and try again.'
  }
}
async function togglePresence() {
  uiError.value = null
  try {
    presence.value = await window.agentcord.setPresenceEnabled(
      !presence.value.enabled,
    )
  } catch {
    uiError.value = 'Discord Rich Presence could not be changed.'
  }
}
async function toggleAgent(agent: Agent) {
  uiError.value = null
  try {
    settings.value = await window.agentcord.setAgentEnabled(
      agent,
      !settings.value.agents[agent],
    )
  } catch {
    uiError.value = `${agentName(agent)} could not be changed.`
  }
}
async function toggleUnifiedUsage() {
  uiError.value = null
  try {
    settings.value = await window.agentcord.setUnifiedUsage(
      !settings.value.unifiedUsage,
    )
  } catch {
    uiError.value = 'Unified usage could not be changed.'
  }
}
async function toggleLaunchAtLogin() {
  if (launchBusy.value || !launchAtLogin.value.supported) return
  launchBusy.value = true
  uiError.value = null
  try {
    launchAtLogin.value = await window.agentcord.setLaunchAtLogin(
      !launchAtLogin.value.enabled,
    )
  } catch {
    uiError.value = 'Launch at login could not be changed.'
  } finally {
    launchBusy.value = false
  }
}
async function hide() {
  try {
    await window.agentcord.hideWindow()
  } catch {
    uiError.value = 'The window could not be hidden.'
  }
}
async function quit() {
  try {
    await window.agentcord.quit()
  } catch {
    uiError.value = 'The application could not be closed.'
  }
}
function onKeyDown(event: KeyboardEvent) {
  if (event.key !== 'Escape') return
  event.preventDefault()
  if (page.value !== 'main') navigate('main')
  else void hide()
}
function resize() {
  if (!popover.value || !bridgeAvailable.value) return
  const height = Math.ceil(popover.value.getBoundingClientRect().height + 20)
  if (height === lastHeight) return
  lastHeight = height
  void window.agentcord.resizeWindow(height).catch(() => {
    lastHeight = 0
  })
}
watch(page, async () => {
  await nextTick()
  resize()
})
onMounted(async () => {
  timer = setInterval(() => {
    now.value = Date.now()
  }, 1000)
  document.addEventListener('keydown', onKeyDown)
  if (!window.agentcord) {
    uiError.value =
      'Open this app through Electron (npm run dev), not a standalone browser.'
    return
  }
  bridgeAvailable.value = true
  // Reset only on a native reopen, not browser visibility/occlusion changes
  // caused by resizing or loading fonts while navigating between screens.
  unsubscribeWindowShown = window.agentcord.onWindowShown(() =>
    navigate('main'),
  )
  observer = new ResizeObserver(resize)
  if (popover.value) observer.observe(popover.value)
  let events = 0
  unsubscribe = window.agentcord.onUsage((value) => {
    events++
    applyState(value)
  })
  const providerEvents = new Set<TokenProvider>()
  unsubscribeProviders = window.agentcord.onProviderUsage((name, value) => {
    providerEvents.add(name)
    providerStates.value[name] = value
  })
  let activeEvents = 0
  unsubscribeClaudeActive = window.agentcord.onClaudeActive((value) => {
    activeEvents++
    claudeActive.value = value
  })
  let presenceEvents = 0
  unsubscribePresence = window.agentcord.onPresence((value) => {
    presenceEvents++
    presence.value = value
  })
  try {
    const [
      initial,
      providerInitial,
      activeInitial,
      presenceInitial,
      loginInitial,
      settingsInitial,
    ] = await Promise.all([
        window.agentcord.getUsage(),
        Promise.all(providerNames.map((name) => window.agentcord.getProviderUsage(name))),
        window.agentcord.getClaudeActive(),
        window.agentcord.getPresence(),
        window.agentcord.getLaunchAtLogin(),
        window.agentcord.getSettings(),
      ])
    launchAtLogin.value = loginInitial
    settings.value = settingsInitial
    providerNames.forEach((name, index) => {
      if (!providerEvents.has(name))
        providerStates.value[name] = providerInitial[index]
    })
    if (!activeEvents) claudeActive.value = activeInitial
    if (!events) applyState(initial)
    if (!presenceEvents) presence.value = presenceInitial
  } catch {
    uiError.value = 'Could not read usage from the desktop application.'
  }
})
onUnmounted(() => {
  unsubscribe?.()
  unsubscribeProviders?.()
  unsubscribeClaudeActive?.()
  unsubscribePresence?.()
  unsubscribeWindowShown?.()
  if (timer) clearInterval(timer)
  observer?.disconnect()
  document.removeEventListener('keydown', onKeyDown)
})
</script>

<template>
  <div class="window-frame">
    <main ref="popover" class="popover" :data-screen="page">
      <template v-if="page === 'main'">
        <header class="main-header drag-region">
          <img class="brand-mark" :src="logoUrl" alt="" draggable="false" />
          <h1>agentcord</h1>
          <span
            class="status-pill"
            :class="state.status"
            title="Codex usage connection, not Discord presence"
            ><i></i>{{ statusText }}</span
          >
        </header>
        <button
          v-if="settings.unifiedUsage && enabledAgents.length > 1"
          class="card unified-usage"
          data-unified-usage
          @click="navigate('usage')"
        >
          <span
            v-for="row in unifiedRows"
            :key="row.agent"
            class="compact-row"
            :class="row.window.severity"
            ><span>{{ row.window.label }}</span
            ><span class="progress"
              ><span
                :style="{ width: `${Math.max(1.5, row.window.usedPercent)}%` }"
              ></span></span
            ><strong>{{ Math.round(row.window.usedPercent) }}%</strong></span
          >
          <p v-if="!unifiedRows.length" class="empty-usage">
            No connected agents
          </p>
        </button>
        <section class="card agent-list">
          <button
            v-if="settings.agents.codex"
            class="agent-row"
            data-open-codex
            @click="navigate('codex')"
          >
            <span class="agent-title"
              ><strong>Codex</strong
              ><small>{{ rowStatus(state) }}</small></span
            >
            <span class="agent-trailing" :class="{ connect: !snapshot }">{{
              snapshot
                ? `${Math.round(snapshot.windows[0]?.usedPercent ?? 0)}% used`
                : 'Connect'
            }}</span>
            <Icon name="arrow" :size="11" class="chevron" />
          </button>
          <button
            v-for="name in enabledProviders"
            :key="name"
            class="agent-row"
            :data-open-provider="name"
            @click="navigate(name)"
          >
            <span class="agent-title"
              ><strong>{{ providers[name].name }}</strong
              ><small>{{
                rowStatus(providerStates[name]) +
                (name === 'claude' && claudeActive ? ' · Desktop active' : '')
              }}</small></span
            >
            <span
              class="agent-trailing"
              :class="{ connect: !providerStates[name].snapshot }"
              >{{
                providerStates[name].snapshot
                  ? providerStates[name].snapshot.windows.length
                    ? `${Math.round(providerStates[name].snapshot.windows[0].usedPercent)}% used`
                    : 'Idle'
                  : 'Connect'
              }}</span
            >
            <Icon name="arrow" :size="11" class="chevron" />
          </button>
          <p v-if="!enabledAgents.length" class="empty-usage">
            No agents enabled
          </p>
        </section>
        <button
          class="navigation-row soft-card"
          data-open-settings
          @click="navigate('settings')"
        >
          <Icon name="settings" :size="14" /><span>Settings</span
          ><small>{{
            enabledAgents.length === 1
              ? '1 agent on'
              : `${enabledAgents.length} agents on`
          }}</small
          ><Icon name="arrow" :size="11" class="chevron" />
        </button>
        <div v-if="uiError" class="notice" role="status">{{ uiError }}</div>
        <div class="divider"></div>
        <button class="quit-row" @click="quit">
          <span>Quit agentcord</span><small>Alt+F4</small>
        </button>
      </template>

      <template v-else>
        <header class="screen-header drag-region">
          <button
            class="back-button"
            aria-label="Back to main screen"
            data-back
            @click="navigate('main')"
          >
            <Icon name="arrow" :size="13" />
          </button>
          <h1>{{ screenTitle }}</h1>
        </header>
        <section v-if="page === 'usage'" class="card unified-detail">
          <UsageCard
            v-for="row in unifiedRows"
            :key="row.agent"
            :window="row.window"
            :now="now"
          />
          <p v-if="!unifiedRows.length" class="empty-usage">
            No connected agents
          </p>
        </section>
        <template v-else-if="page !== 'settings'">
          <section class="card detail-card">
            <div class="account-row">
              <button
                class="account-button"
                :disabled="!snapshot?.email"
                :aria-label="
                  snapshot?.email
                    ? emailRevealed
                      ? 'Hide email'
                      : 'Show email'
                    : `${providerName} account`
                "
                :title="
                  snapshot?.email
                    ? emailRevealed
                      ? 'Hide email'
                      : 'Show email'
                    : undefined
                "
                @click="emailRevealed = !emailRevealed"
              >
                <span>{{ accountLabel }}</span
                ><Icon
                  v-if="snapshot?.email"
                  :name="emailRevealed ? 'eye-off' : 'eye'"
                  :size="12"
                />
              </button>
              <span v-if="plan" class="plan-chip">{{ plan }}</span>
            </div>
            <div class="usage-summary">
              <div>
                <Icon name="clock" :size="13" /><span>Subscription usage</span
                ><small :class="active.status">{{
                  active.status === 'ready'
                    ? 'live'
                    : active.status === 'cached'
                      ? 'cached'
                      : '—'
                }}</small>
              </div>
              <p>{{ updated }}</p>
            </div>
            <div v-if="snapshot?.windows.length" class="usage-rows">
              <UsageCard
                v-for="usageWindow in snapshot.windows"
                :key="usageWindow.id"
                :window="usageWindow"
                :now="now"
              />
            </div>
            <p
              v-else
              class="empty-usage"
              :aria-busy="active.refreshing || active.status === 'loading'"
            >
              {{
                active.refreshing || active.status === 'loading'
                  ? `Waiting for ${providerName} usage…`
                  : active.status === 'api-key'
                    ? 'ChatGPT subscription required'
                    : snapshot
                      ? 'Idle · no active usage window'
                      : 'No usage available'
              }}
            </p>
            <div
              v-if="
                snapshot?.credits?.hasCredits || snapshot?.credits?.unlimited
              "
              class="credit-row"
            >
              <span>Additional credits</span
              ><strong>{{
                snapshot.credits.unlimited
                  ? 'Unlimited'
                  : (snapshot.credits.balance ?? '—')
              }}</strong>
            </div>
            <div v-if="notice" class="notice" role="status">{{ notice }}</div>
            <div
              v-if="
                !snapshot && !active.refreshing && active.status !== 'loading'
              "
              class="login-help"
            >
              <p>
                {{
                  meta?.help ??
                  'Sign in to Codex with your ChatGPT account, then refresh.'
                }}
              </p>
              <code>{{ meta?.command ?? 'codex login' }}</code>
            </div>
            <button
              class="refresh-row"
              :disabled="active.refreshing || cooldown > 0 || !bridgeAvailable"
              @click="refresh"
            >
              <Icon
                name="refresh"
                :size="12"
                :class="{ spinning: active.refreshing }"
              /><span>{{ refreshLabel }}</span>
            </button>
          </section>
        </template>

        <template v-else>
          <section class="settings-section">
            <div class="setting-row">
              <span id="launch-at-login-label">Launch at login</span>
              <small v-if="!launchAtLogin.supported">Packaged app only</small>
              <button
                v-else
                class="switch"
                role="switch"
                data-launch-at-login
                aria-labelledby="launch-at-login-label"
                :aria-checked="launchAtLogin.enabled"
                :disabled="launchBusy"
                @click="toggleLaunchAtLogin"
              ></button>
            </div>
          </section>
          <section class="soft-card provider-settings">
            <h2>DISCORD</h2>
            <div class="setting-row">
              <span class="provider-name">Rich Presence</span>
              <span class="switch-group"
                ><small data-presence-status>{{ presenceText }}</small
                ><button
                  class="switch"
                  role="switch"
                  data-presence-switch
                  aria-label="Discord Rich Presence"
                  :aria-checked="presence.enabled"
                  :disabled="!bridgeAvailable"
                  @click="togglePresence"
                ></button
              ></span>
            </div>
          </section>
          <section class="soft-card provider-settings">
            <h2>AGENTS</h2>
            <div v-for="agent in agentNames" :key="agent" class="setting-row">
              <span class="provider-name"><i></i>{{ agentName(agent) }}</span
              ><button
                class="switch"
                role="switch"
                :data-agent-switch="agent"
                :aria-label="agentName(agent)"
                :aria-checked="settings.agents[agent]"
                :disabled="!bridgeAvailable"
                @click="toggleAgent(agent)"
              ></button>
            </div>
          </section>
          <section class="soft-card provider-settings">
            <h2>DISPLAY</h2>
            <div class="setting-row">
              <span id="unified-usage-label">Show unified usage</span
              ><button
                class="switch"
                role="switch"
                data-unified-usage-switch
                aria-labelledby="unified-usage-label"
                :aria-checked="settings.unifiedUsage"
                :disabled="!bridgeAvailable"
                @click="toggleUnifiedUsage"
              ></button>
            </div>
          </section>
        </template>
      </template>
    </main>
  </div>
</template>
