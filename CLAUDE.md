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

## Worker 工作规则（由 dev-forge Supervisor 派发时适用）

本节规则在 dev-forge 系统以无人值守方式派发 Task 时生效；人工交互开发时可按需参考。

- **只做当前 Task**：你是 Worker，只执行本次下发的 Task，不要主动读取无关文档或扩大改动范围。背景知识以 `docs/watchtower-project-plan.md` 为准，不要每次重新扫描全仓库。
- **修改范围**：以 Task 下发的 `allowed_paths` 为准。范围外文件一律禁止修改（PreToolUse `pretooluse-path-guard.sh` 会硬性拦截 Write/Edit 及可识别的 Bash 写入）；确需改动范围外文件时，停止并在输出中说明原因，不要绕过守卫。
- **测试 / 验证**：`npm run test && npm run build` 两条都必须通过（与项目 `verifyCommand` 一致）。自测时优先跑受影响模块的 Vitest 用例，收尾前完整跑一遍。
- **完成信号**：自测结束后把结果写入 `docs/tasks/<taskCode>.result.json`，内容为：
  ```json
  { "status": "PASSED", "summary": "可选摘要", "taskCode": "TASK-XXX" }
  ```
  `status` 取 `PASSED` 或 `FAILED`。Supervisor 在进程退出后读取该文件并代为上报；**不要**自己执行 `sdlc test-result`（目标仓库没有该命令），也不要只在纯文本里声称"完成"。
- **失败上报 / NEEDS_DECISION 判定**：
  - 可自行处理：测试失败、类型错误、lint 报错、依赖已声明但未安装等——在 `allowed_paths` 内修复并重跑，不升级。
  - 需人工决策（停下并把结果写成 `FAILED`，在 `summary` / 输出中说明）：需求或验收标准不明确、必须修改 `allowed_paths` 外文件、需要新增或更换依赖、改变技术栈、发现敏感凭据、需要执行 git push 等超出自动化边界（commit 以外）的操作。
- **提交规则**：**系统自动提交，Worker 不提交**。不要执行 `git add` / `git commit` / `git push`；Task 验证通过后由 Supervisor 调用 `commitTask()` 完成提交，提交信息由系统生成。
- **状态更新**：状态一律以数据库为准。不要手工修改 `docs/` 下文档 front-matter 里的 `status` / `depends_on` 等字段来驱动系统；系统会在状态变化后回写镜像。
