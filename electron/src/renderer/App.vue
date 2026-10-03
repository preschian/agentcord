<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import type {
  ClaudeUsageState,
  PresenceState,
  LaunchAtLoginState,
  UsageState,
} from '../shared/types'
import Icon from './components/Icon.vue'
import UsageCard from './components/UsageCard.vue'
import { ago, maskEmail } from './format'

const logoUrl = `${import.meta.env.BASE_URL}agentcord.png`
const page = ref<'main' | 'codex' | 'claude' | 'settings'>('main')
const popover = ref<HTMLElement | null>(null)
const emailRevealed = ref(false)
const installationExpanded = ref(false)
const state = ref<UsageState>({
  status: 'loading',
  snapshot: null,
  refreshing: false,
  message: null,
  nextRefreshAt: 0,
  codexHome: '',
  executable: null,
})
const claudeState = ref<ClaudeUsageState>({
  status: 'loading',
  snapshot: null,
  refreshing: false,
  message: null,
  nextRefreshAt: 0,
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
const launchAtLogin = ref<LaunchAtLoginState>({ supported: false, enabled: false })
const launchBusy = ref(false)
const now = ref(Date.now())
const uiError = ref<string | null>(null)
const bridgeAvailable = ref(false)
let unsubscribe: (() => void) | undefined
let unsubscribeClaude: (() => void) | undefined
let unsubscribeClaudeActive: (() => void) | undefined
let unsubscribePresence: (() => void) | undefined
let unsubscribeWindowShown: (() => void) | undefined
let timer: ReturnType<typeof setInterval> | undefined
let observer: ResizeObserver | undefined
let lastHeight = 0
const isClaude = computed(() => page.value === 'claude')
const providerName = computed(() => (isClaude.value ? 'Claude' : 'Codex'))
// Detail screens read from whichever provider is open; Codex is the default.
const active = computed<ClaudeUsageState>(() =>
  isClaude.value ? claudeState.value : state.value,
)
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
    : isClaude.value
      ? 'Anthropic / Claude'
      : 'OpenAI / ChatGPT'
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
    if (isClaude.value) claudeState.value = await window.agentcord.refreshClaudeUsage()
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
  let claudeEvents = 0
  unsubscribeClaude = window.agentcord.onClaudeUsage((value) => {
    claudeEvents++
    claudeState.value = value
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
    const [initial, claudeInitial, activeInitial, presenceInitial, loginInitial] =
      await Promise.all([
        window.agentcord.getUsage(),
        window.agentcord.getClaudeUsage(),
        window.agentcord.getClaudeActive(),
        window.agentcord.getPresence(),
        window.agentcord.getLaunchAtLogin(),
      ])
    launchAtLogin.value = loginInitial
    if (!claudeEvents) claudeState.value = claudeInitial
    if (!activeEvents) claudeActive.value = activeInitial
    if (!events) applyState(initial)
    if (!presenceEvents) presence.value = presenceInitial
  } catch {
    uiError.value = 'Could not read usage from the desktop application.'
  }
})
onUnmounted(() => {
  unsubscribe?.()
  unsubscribeClaude?.()
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
        <section class="card agent-list">
          <button class="agent-row" data-open-codex @click="navigate('codex')">
            <span class="agent-title"
              ><strong>Codex</strong
              ><small>{{
                snapshot
                  ? state.status === 'cached'
                    ? 'Cached usage'
                    : 'Connected'
                  : state.status === 'loading'
                    ? 'Connecting…'
                    : 'Not connected'
              }}</small></span
            >
            <span class="agent-trailing" :class="{ connect: !snapshot }">{{
              snapshot
                ? `${Math.round(snapshot.windows[0]?.usedPercent ?? 0)}% used`
                : 'Connect'
            }}</span>
            <Icon name="arrow" :size="11" class="chevron" />
          </button>
          <button class="agent-row" data-open-claude @click="navigate('claude')">
            <span class="agent-title"
              ><strong>Claude</strong
              ><small>{{
                (claudeState.snapshot
                  ? claudeState.status === 'cached'
                    ? 'Cached usage'
                    : 'Connected'
                  : claudeState.status === 'loading'
                    ? 'Connecting…'
                    : 'Not connected') + (claudeActive ? ' · Desktop active' : '')
              }}</small></span
            >
            <span
              class="agent-trailing"
              :class="{ connect: !claudeState.snapshot }"
              >{{
                claudeState.snapshot
                  ? `${Math.round(claudeState.snapshot.windows[0]?.usedPercent ?? 0)}% used`
                  : 'Connect'
              }}</span
            >
            <Icon name="arrow" :size="11" class="chevron" />
          </button>
        </section>
        <button
          class="navigation-row soft-card"
          data-open-settings
          @click="navigate('settings')"
        >
          <Icon name="settings" :size="14" /><span>Settings</span
          ><small>Usage only</small
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
          <h1>{{ page === 'settings' ? 'Settings' : providerName }}</h1>
        </header>
        <template v-if="page !== 'settings'">
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
            <div v-if="snapshot" class="usage-rows">
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
              <p v-if="isClaude">Sign in to Claude Code, then refresh.</p>
              <p v-else>Sign in to Codex with your ChatGPT account, then refresh.</p>
              <code>{{ isClaude ? 'claude /login' : 'codex login' }}</code>
            </div>
            <button
              class="refresh-row"
              :disabled="active.refreshing || cooldown > 0 || !bridgeAvailable"
              @click="refresh"
            >
              <Icon
                name="refresh"
                :size="12"
                :class="{ spinning: state.refreshing }"
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
            <div class="setting-row">
              <span>Auto-refresh</span><small>5m · while visible</small>
            </div>
            <div class="setting-row">
              <span>Refresh cooldown</span><small>1m</small>
            </div>
            <div class="setting-row">
              <span>Usage cache</span><small>Up to 24h</small>
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
            <p class="setting-hint">
              Shares your usage percentages on your Discord profile while the
              Discord app is running. Off by default.
            </p>
          </section>
          <section class="soft-card provider-settings">
            <h2>AGENTS</h2>
            <div class="setting-row">
              <span class="provider-name"><i></i>Codex</span
              ><small>Usage only</small>
            </div>
            <div class="setting-row">
              <span class="provider-name"><i></i>Claude</span
              ><small>Usage only</small>
            </div>
          </section>
          <section class="soft-card installation-card">
            <button
              class="navigation-row"
              :aria-expanded="installationExpanded"
              @click="installationExpanded = !installationExpanded"
            >
              <span>Installation</span
              ><Icon
                name="arrow"
                :size="11"
                class="chevron"
                :class="{ expanded: installationExpanded }"
              />
            </button>
            <dl v-if="installationExpanded">
              <dt>Codex home</dt>
              <dd>{{ state.codexHome || 'Initializing…' }}</dd>
              <dt>Codex executable</dt>
              <dd>{{ state.executable || 'Not found / not checked yet' }}</dd>
              <dt>Claude sign-in</dt>
              <dd>Read from Claude Code's ~/.claude/.credentials.json.</dd>
              <dt>Configuration</dt>
              <dd>
                Set CODEX_HOME, CODEX_BINARY or CLAUDE_CONFIG_DIR before
                starting the app.
              </dd>
            </dl>
          </section>
          <section class="soft-card about-card">
            <h2>Electron preview</h2>
            <p>
              Codex / ChatGPT and Claude subscription limits only. Session
              tracking and API billing are not included.
            </p>
            <p>
              Credentials stay with Codex and Claude Code. Cached results are marked; account
              changes clear old usage.
            </p>
          </section>
          <button class="navigation-row soft-card" @click="hide">
            <Icon name="hide" :size="14" /><span>Hide to tray</span
            ><small>Esc</small>
          </button>
          <p class="version">agentcord 0.1.0 · Electron + Vue</p>
        </template>
      </template>
    </main>
  </div>
</template>
