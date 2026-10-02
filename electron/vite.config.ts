import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  root: fileURLToPath(new URL('./src/renderer', import.meta.url)),
  base: './',
  publicDir: fileURLToPath(new URL('./out/assets', import.meta.url)),
  plugins: [vue()],
  build: {
    outDir: '../../out/renderer',
    emptyOutDir: true,
  },
  server: { host: '127.0.0.1' },
})
