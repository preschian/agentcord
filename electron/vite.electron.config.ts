import { defineConfig } from 'vite'
import { isBuiltin } from 'node:module'
import { fileURLToPath } from 'node:url'

export default defineConfig(({ mode }) => {
  if (mode !== 'main' && mode !== 'preload') throw new Error('Use --mode main or preload')
  return {
    build: {
      target: 'node24',
      outDir: `out/${mode}`,
      emptyOutDir: true,
      lib: {
        entry: fileURLToPath(new URL(`./src/${mode}/index.ts`, import.meta.url)),
        formats: ['cjs'],
        fileName: () => 'index.cjs',
      },
      rolldownOptions: {
        external: (id) => id === 'electron' || isBuiltin(id),
      },
    },
  }
})
