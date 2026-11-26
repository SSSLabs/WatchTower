#!/usr/bin/env bash
# ============================================================
# AI SDLC 自动化系统 — Stop Hook 模板（会话结束时落盘会话摘要）
#
# 设计依据：详细设计 §2.2（Hook 集成）/ §5.2（.claude/hooks 骨架）
#
# 职责：Claude Code（Worker）一次会话结束时触发，把本次 session 的摘要与
# 定位线索**写进 Supervisor 指定的文件**（$SDLC_SESSION_END_FILE）。Supervisor 在
# 子进程退出后读走该文件，落一条 SESSION_END 事件（见 dev-forge 的
# src/supervisor/sessionEnd.ts）。定位信息（projectId / taskId / workerSessionId）
# 由 Supervisor 落库时自己填，本脚本**不需要也不应该**去伪造它并不知道的身份字段。
#
# 为什么不是 HTTP（背景见 docs/system/ARCH-000-existing-system.md §9 T10）：本脚本原先把摘要 POST 到
# {SDLC_SUPERVISOR_BASE_URL}/api/hooks/stop，但那个接收端从未实现，且 payload 里的
# 定位字段在真实链路下恒为 null（Supervisor 从不注入它们），所以即便补上接收端也
# 认不出是哪个 WorkerSession——每次真实会话都往虚空 POST 一次，失败只进 .stderr.log。
# 现改为「落盘 → Supervisor 读走」，不引入任何 HTTP 面。
#
# 定位：这份摘要**不是完成信号**。一次性 `claude -p` 形态下进程退出本身就是
# 「会话结束」；完成信号仍走 docs/tasks/<taskCode>.result.json。本文件提供的是
# 一个不必打开数 MB transcript 就能查的「会话结束 + 它最后说了什么」标记。
#
# 输入：Claude Code 通过 stdin 传入 Stop hook JSON：
#       { session_id, transcript_path, cwd, hook_event_name: "Stop" }。
# 输出：总是 exit 0 —— Stop Hook 没有放行/拒绝语义，且绝不能因落盘失败而
#       打断正在收尾的 Claude Code 会话；落盘失败只在 stderr 打一条诊断。
#
# 环境变量（Supervisor spawn Worker 时注入；本脚本只认这一个落点）：
#   SDLC_UNATTENDED             无人值守总开关（见下方"无人值守门控"）：置
#                               0/false/off/no（大小写不敏感）= 强制关闭；未设置时
#                               按 SDLC_SESSION_END_FILE 推断（为空即视为人工会话）
#   SDLC_SESSION_END_FILE       会话结束报告的落盘路径。**未提供即什么都不做**——
#                               没有落点就没有这件事，不再有"POST 到不存在的端点"。
#   SDLC_STOP_SUMMARY           覆盖会话摘要（否则从 transcript 末尾尽力提取）
#
# 依赖：bash + node。机器上必有 node：AI SDLC 系统自身是 Node 工程。
# ============================================================

set -u

# ============================================================
# 无人值守门控（廉价短路：先于 node 启动）
#
# 本 hook 只服务于「Supervisor 无人值守派发 Worker」这一场景。人工交互式会话下
# 每次会话收尾都拉起 node 去落一份没人读的文件，纯属噪音。故在最前面用纯 shell
# 判一次，非无人值守直接退 0，完全不启动 node。
#
# 判定口径（只看环境变量，不做任何 IO）：
#   1) SDLC_UNATTENDED 取显式关闭值（0/false/off/no，大小写不敏感）-> 关闭
#      （人工会话里哪怕残留了 SDLC_* 也能一键排除干扰）
#   2) 未显式设置 SDLC_UNATTENDED，且没有落点（SDLC_SESSION_END_FILE 为空）
#      -> 视为人工会话 -> 关闭
#
# 注：与 pretooluse-path-guard.sh 同一口径（同一套"显式开关优先、否则按接线推断"
# 规则，只是各自看自己的接线变量）。Supervisor 侧由 envGuard.injectPathGuardEnv
# 显式注入 SDLC_UNATTENDED=1。
# ============================================================
case "${SDLC_UNATTENDED:-}" in
  0 | [Ff][Aa][Ll][Ss][Ee] | [Oo][Ff][Ff] | [Nn][Oo]) exit 0 ;;
esac

if [ -z "${SDLC_UNATTENDED:-}" ] && [ -z "${SDLC_SESSION_END_FILE:-}" ]; then
  exit 0
fi

# 没有落点就不做事（显式 SDLC_UNATTENDED=1 但没给落点的情形也走这里）
if [ -z "${SDLC_SESSION_END_FILE:-}" ]; then
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  echo "stop-hook: 缺少 node 运行时，跳过会话摘要落盘" >&2
  exit 0
fi

# stdin 原样透传给 node：hook JSON 不落地、不走命令行参数。
node -e "$(cat <<'NODE'
const fs = require("fs");
const path = require("path");

// ---- 解析 hook 输入（Stop：session_id / transcript_path / cwd）----
let hook = {};
try {
  hook = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
} catch (e) {
  console.error("stop-hook: 无法解析 hook 输入（非 JSON），跳过落盘: " + e.message);
  process.exit(0);
}

const sessionId = hook.session_id || null;
const transcriptPath = hook.transcript_path || null;
const cwd = hook.cwd || null;

// ---- 会话摘要：优先取 env 注入，否则从 transcript 末尾找最后一段助手文本 ----
function lastAssistantText(file) {
  try {
    const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (!line) continue;
      let rec = null;
      try { rec = JSON.parse(line); } catch (e) { continue; }
      const msg = rec && rec.message;
      if (rec && rec.type === "assistant" && msg && Array.isArray(msg.content)) {
        const parts = msg.content
          .filter((c) => c && c.type === "text" && typeof c.text === "string")
          .map((c) => c.text);
        if (parts.length > 0) return parts.join("\n");
      }
    }
  } catch (e) {
    /* transcript 不可读则忽略，走默认摘要 */
  }
  return "";
}

let summary = process.env.SDLC_STOP_SUMMARY;
if (!summary && transcriptPath) summary = lastAssistantText(transcriptPath).trim();
if (!summary) summary = "Claude Code 会话结束（无文本摘要）";
if (summary.length > 800) summary = summary.slice(0, 800) + "…";

const payload = {
  hook_event_name: "Stop",
  session_id: sessionId,
  transcript_path: transcriptPath,
  cwd: cwd,
  summary: summary,
  sent_at: new Date().toISOString(),
};

const target = process.env.SDLC_SESSION_END_FILE;

try {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, JSON.stringify(payload, null, 2) + "\n", "utf8");
} catch (e) {
  const msg = e && e.message ? e.message : String(e);
  console.error("stop-hook: 写会话结束报告失败（忽略，不影响会话收尾）: " + msg);
}
NODE
)"
exit 0
