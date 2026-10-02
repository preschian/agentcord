<script setup lang="ts">
import { computed } from 'vue'
import type { UsageWindow } from '../../shared/types'
import { windowValue } from '../format'
const props = defineProps<{ window: UsageWindow; now: number }>()
const value = computed(() => windowValue(props.window, props.now))
const tooltip = computed(() => {
  const remaining = `${100 - Math.round(props.window.usedPercent)}% remaining`
  return props.window.resetsAt
    ? `${remaining} · resets ${new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeStyle: 'short' }).format(props.window.resetsAt)}`
    : `${remaining} · reset time unavailable`
})
</script>

<template>
  <div
    class="usage-row"
    :class="window.severity"
    :title="tooltip"
    data-usage-card
  >
    <div class="usage-row-header">
      <span>{{ window.label }}</span
      ><strong>{{ value }}</strong>
    </div>
    <div
      class="progress"
      role="progressbar"
      :aria-label="`${window.label}: used`"
      :aria-valuenow="window.usedPercent"
      aria-valuemin="0"
      aria-valuemax="100"
    >
      <div :style="{ width: `${Math.max(1.5, window.usedPercent)}%` }"></div>
    </div>
  </div>
</template>
