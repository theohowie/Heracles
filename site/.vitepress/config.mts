import { defineConfig } from 'vitepress'

// Heracles 项目主页（GitHub Pages 项目页：https://theohowie.github.io/Heracles/）
//
// ⚠️ `base` 必须匹配仓库名大小写（GitHub Pages 项目页带这个前缀）。
// 本地预览：pnpm dev；构建：pnpm build（产物在 .vitepress/dist）
export default defineConfig({
  lang: 'zh-CN',
  title: 'Heracles',
  description: '手机上的开发智能体 —— 一个跑在 Android 上的 AI 编程 App',
  base: '/Heracles/',
  cleanUrls: true,
  lastUpdated: true,

  head: [
    ['meta', { name: 'theme-color', content: '#0b0b0c' }],
    ['meta', { property: 'og:title', content: 'Heracles —— 手机上的开发智能体' }],
    ['meta', { property: 'og:description', content: '在 Android 手机上读代码、改文件、跑命令，甚至直接构建 APK。BYOK，云端模型。' }],
    ['meta', { property: 'og:type', content: 'website' }],
  ],

  themeConfig: {
    logo: '/logo.svg',
    siteTitle: 'Heracles',

    nav: [
      { text: '简介', link: '/' },
      { text: '快速开始', link: '/guide/getting-started' },
      { text: '界面截图', link: '/shots' },
      { text: '从源码构建', link: '/guide/build' },
      { text: '功能与限制', link: '/status' },
    ],

    sidebar: [
      {
        text: '开始',
        items: [
          { text: '这是什么', link: '/' },
          { text: '快速开始', link: '/guide/getting-started' },
          { text: '从源码构建', link: '/guide/build' },
          { text: '界面截图', link: '/shots' },
        ],
      },
      {
        text: '参考',
        items: [
          { text: '功能与限制', link: '/status' },
          { text: '许可（GPL-3.0）', link: '/license' },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/theohowie/Heracles' },
      { icon: 'gitee', link: 'https://gitee.com/theohowie/heracles' },
    ],

    search: { provider: 'local' },

    outline: { level: [2, 3], label: '本页目录' },
    docFooter: { prev: '上一篇', next: '下一篇' },
    darkModeSwitchLabel: '外观',
    lightModeSwitchTitle: '切换到浅色',
    darkModeSwitchTitle: '切换到深色',
    sidebarMenuLabel: '目录',
    returnToTopLabel: '回到顶部',
    lastUpdatedText: '最后更新',

    footer: {
      message: '以 GPL-3.0 许可开源 · 按“现有状态”提供，不含任何担保',
      copyright: 'Copyright © 2026 Theohowie',
    },
  },
})