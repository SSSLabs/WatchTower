# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

WatchTower（瞭望塔）：基于地图的监控 / 观测 Web 应用。第一版是纯前端 SPA，无后端；地图（MapLibre GL JS）是底座与呈现界面，后续阶段在其上叠加态势感知与 C2 能力（完整规划见 `docs/watchtower-project-plan.md`）。

## 技术栈

- Vite + React + TypeScript（strict）
- Tailwind CSS v4（经 `@tailwindcss/vite` 插件接入，`src/index.css` 中 `@import "tailwindcss"`）
- MapLibre GL JS（地图渲染；底图用 demotiles 公开样式，无需 token）
- Vitest（单元测试）
- oxlint（lint）
- npm（包管理）

## 常用命令

```bash
npm run dev      # 启动开发服务器
npm run test     # 运行单元测试（vitest run，非 watch 模式）
npm run build    # 类型检查（tsc -b）+ 生产构建
npm run lint     # oxlint
npm run preview  # 预览生产构建
```

验证命令（verifyCommand）：`npm run test && npm run build`，两条都必须通过。

## 代码规范

- 组件放 `src/components/`，一个组件一个文件，文件名 PascalCase
- 纯工具函数放 `src/lib/`，不依赖 DOM / React / 地图库，配套 `*.test.ts` 单测
- 类型用 TS strict（`tsconfig.app.json` 显式开启 `strict`）
- 样式一律用 Tailwind 工具类，不新增独立 CSS 文件（`src/index.css` 只放全局导入）
- 地图实例在组件 `useEffect` 内创建，卸载时必须 `map.remove()`
- 地图只负责呈现，不做业务计算（融合 / 评估等逻辑后续放纯 TS 模块，见计划书 §4.1）
