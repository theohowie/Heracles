import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// GitHub Pages 项目页：https://theohowie.github.io/Heracles/
export default defineConfig({
  base: '/Heracles/',
  plugins: [react()],
  // 产物直接落到 gh-pages 分支**根目录**（= 本文件的上一级）。
  // 该分支根是 GitHub Pages 的托管目录；源码在 `_source/` 里。
  // ⚠️ emptyOutDir 必须 false —— 否则构建会把 _source/ 一起清掉。
  build: { outDir: '..', assetsDir: 'assets', emptyOutDir: false },
})