<script setup lang="ts">
import { materialSymbols, type IconName } from '../icon-names'

withDefaults(defineProps<{ name: IconName; size?: number }>(), { size: 20 })
</script>

<template>
  <span
    class="material-icon"
    :style="{ fontSize: `${size}px`, width: `${size}px`, height: `${size}px` }"
    aria-hidden="true"
    >{{ materialSymbols[name] }}</span
  >
</template>

<style scoped>
.material-icon {
  display: inline-block;
  flex: 0 0 auto;
  font-family: 'Material Symbols Rounded Variable';
  font-style: normal;
  font-weight: 400;
  font-variation-settings:
    'wght' 400,
    'opsz' 20;
  font-feature-settings: 'liga';
  font-variant-ligatures: normal;
  line-height: 1;
  letter-spacing: normal;
  text-transform: none;
  text-align: center;
  white-space: nowrap;
  overflow: hidden;
  direction: ltr;
  user-select: none;
  -webkit-font-smoothing: antialiased;
}
</style>
