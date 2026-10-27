# 站点源码（`gh-pages` 分支）

这个目录是 **Heracles 落地页的全部源码**。它放在 `gh-pages` 分支里，而不是 `master`。

## 为什么在这里

用户裁定（2026-10-27）：**站点相关的一切文件只允许存在于 `gh-pages` 分支**，
其他分支（`master` / `frontend` / 未来的任何分支）不得包含站点文件。

所以这个分支同时承担两个角色：

| 路径 | 内容 | 谁在用 |
|---|---|---|
| `/`（根目录） | `vite build` 的**产物** | GitHub Pages 直接托管 |
| `/_source/` | 站点**源码**（就是本目录） | 人改站点时进来 |

## 结构

```
gh-pages/
├── index.html          ← 构建产物（自动生成，别手改）
├── assets/             ← 构建产物
├── shots/  video/  logo.png   ← 构建产物（public/ 的拷贝）
├── .nojekyll           ← 关掉 Jekyll 处理
└── _source/            ← 源码（本目录）
    ├── index.html      ← Vite 入口（源码）
    ├── src/Landing.jsx ← 页面主体
    ├── src/main.jsx  src/main.css
    ├── public/         ← 静态资源（logo、截图）
    ├── vite.config.js  ← base = '/Heracles/'
    ├── preview.mjs     ← 本地预览静态服务器
    └── package.json  pnpm-lock.yaml
```

## 改站点的流程

```bash
# 1. 拿到本分支
git fetch origin gh-pages
git checkout gh-pages

# 2. 装依赖并改源码
cd _source
pnpm install
pnpm dev            # 开发预览（http://localhost:5173/Heracles/）

# 3. 构建到分支根目录
pnpm build --outDir ..   --emptyOutDir=false
#    注意：不要 --emptyOutDir（会连 _source/ 一起删掉）

# 4. 提交
cd ..
git add -A
git commit -m "deploy: <改了什么>"
git push origin gh-pages
```

## 本地预览构建产物

```bash
cd _source
node preview.mjs      # http://127.0.0.1:4180/Heracles/
```

`preview.mjs` 默认读 `_source/dist`，只在本地截图时用；正式部署走上面的第 3 步。

## 两条纪律

1. **不要手改根目录的构建产物**（`index.html` / `assets/`）—— 下次 `pnpm build` 会覆盖。
   要改就改 `_source/` 然后重新构建。
2. **不要把站点文件放回 `master`** —— 那是被明确要求禁止的。
