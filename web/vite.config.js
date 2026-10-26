import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// GitHub Pages 项目页：https://theohowie.github.io/Heracles/
export default defineConfig({
  base: '/Heracles/',
  plugins: [react()],
  build: { outDir: 'dist', assetsDir: 'assets' },
})