#!/usr/bin/env bash
# ============================================================
# AI SDLC 自动化系统 — PreToolUse 路径守卫 Hook 模板
#
# 设计依据：详细设计 §9.3（安全性）/ §5.2（.claude/hooks 骨架）
#
# 职责：在 Claude Code（Worker）写/读工具调用之前做两类校验，命中即拒绝并把原因
# 返回给 Worker：
#   (1) 写范围约束：Write/Edit/MultiEdit/NotebookEdit 的目标文件、以及 Bash 命令里
#       能静态识别出的写入目标（重定向 >/>>、tee、sed -i、cp/mv/touch 等、rm 删除）
#       必须落在 Task 下发的 allowed_paths 内，范围外直接拒绝（§9.3 强约束）。
#   (2) 敏感文件硬性拒绝（独立于 allowed_paths）：无论 Read/Bash(cat/grep/type 等)
#       /Grep 还是 Write/Edit，凡是路径命中敏感清单（默认 .env*、*.pem、*secret*、
#       *credentials* 等，见下 SDLC_SENSITIVE_PATH_PATTERNS）一律拒绝访问。
#       目的不是限制修改范围，而是防止真实密钥内容被读进 transcript 或经 stop-hook
#       上报出去——Worker 做代码升级/安全审查/重构都不需要看到密钥的实际值。
#
# 2024-09 加固说明（Bash 覆盖）：此前只拦 Write/Edit/MultiEdit/NotebookEdit，Worker
# 用 `echo x > file` 之类 Bash 命令即可绕过。现对 Bash 的 command 字段做尽力而为的
# 静态检测：识别常见写入/修改模式并校验其目标路径；无法可靠解析出目标路径的
# 复杂/可疑命令（内联代码执行 node -e/python -c、命令替换 `> $(...)`、变量拼路径、
# glob 展开目标等）保守起见直接拒绝而不是放行；另对与路径无关的高危命令
# （git push/reset --hard、chmod/chown、curl|sh 下载即执行、rm 根目录等）无条件硬拒绝。
# 复合命令（&&、;、|、||）会拆成子命令分别校验，并进一步把藏在 $()、反引号、
# 子 shell(...)、进程替换 <(...)/>(...) 里的内层可执行内容也拆出来当独立子命令校验：
# 只要任意一个子命令越界、命中高危/敏感清单或解析不出写入目标，整条命令就被拒绝，
# 不会因为第一个子命令"看起来安全"而放行。
#
# 必须如实声明：**这仍然不是完整沙箱**。静态分析无法覆盖任意命令的间接写入
# （被调脚本内部、eval 出来的字符串、管道里藏的重定向等都已尽量按"解析不出即拒绝"
# 处理），但不可能穷尽；本 Hook 的价值是把覆盖面从"完全不管 Bash"提高到
# "挡住常见/明显的越界写入"，而不是替代对 Worker 的信任边界。
#
# 对应配置：settings.json 里本 Hook 的 PreToolUse matcher 需覆盖
#   Bash|Read|Grep|Write|Edit|MultiEdit|NotebookEdit
# 否则 Read/Grep/Bash 的调用不会进到本脚本，敏感文件规则对它们不生效。
#
# 输入：Claude Code 通过 stdin 传入 PreToolUse hook JSON，含
#       { session_id, cwd, hook_event_name, tool_name, tool_input:{...} }。
# 输出：
#   - 放行：exit 0（stdout 无输出）
#   - 拒绝：exit 2，stdout 输出 Claude Code 可解析的 deny JSON
#       {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#         "permissionDecision":"deny","permissionDecisionReason":"..."}}
#
# 环境变量（Supervisor spawn Worker 时注入；手动运行不设 = 守卫关闭）：
#   SDLC_UNATTENDED                   无人值守总开关（见下方"无人值守门控"）：置
#                                     0/false/off/no（大小写不敏感）= 强制关闭本守卫，
#                                     人工交互会话可用它排除环境里残留的 SDLC_* 干扰；
#                                     未设置时按接线变量推断（收到下面任一即启用）
#   SDLC_ALLOWED_PATHS                allowed_paths：JSON 数组（如 '["src/**"]'）
#                                     或每行一个 glob；空串视为未配置（守卫关闭），
#                                     '[]' 视为已配置且范围为空（拒绝一切写入）
#   SDLC_ALLOWED_PATHS_FILE           同上，指向一个文件（每行一个 glob，# 开头为注释）
#                                     与 SDLC_ALLOWED_PATHS 同时提供时取并集
#   SDLC_SENSITIVE_PATH_PATTERNS      敏感文件 glob 清单（JSON 数组或每行一个 glob），
#                                     设置后**替换**下面内置默认清单；用于扩展/收窄。
#                                     守卫开启时若未设置则用内置默认清单。
#                                     默认：**/.env*  **/*.pem  **/*.p12  **/*.pfx
#                                           **/.ssh/**  **/id_rsa*  **/id_ed25519*
#                                           **/*secret*  **/*credentials*
#                                     注：*secret*/*credentials* 是子串匹配，若源码里
#                                     恰有 secretPage.tsx 这类非敏感命名的文件会被误伤，
#                                     可按需用本变量收窄清单。
#   SDLC_REPO_ROOT                    目标仓库根目录（缺省取 hook JSON 的 cwd / $PWD）
#   SDLC_RESULT_FILE                  完成信号结果文件的**确切路径**（docs/tasks/<taskCode>.result.json，
#                                     相对仓库根或绝对路径）。这是 allowed_paths 之外唯一被放行的写入目标：
#                                     DEVELOPER Worker 自测通过/失败要把结果写进该文件（supervisor 读取后
#                                     作为完成信号，见 dev-forge src/supervisor/workerReport.ts），不豁免会被本
#                                     守卫自锁。仅精确命中该路径的文件放行，docs/tasks/ 下其它文件仍受约束。
#                                     未设置 = 无豁免。
#   SDLC_PATH_GUARD_CASE_INSENSITIVE  置 1 强制忽略路径大小写（默认 Windows 忽略）
#   SDLC_PATH_GUARD_DEBUG             置 1 在 stderr 打印判定过程（排障用）
#
# 匹配规则（相对仓库根、正斜杠比较，与 allowed_paths 同）：
#   - 无通配符的模式 = 精确匹配单个文件
#   - 以 / 结尾的模式 = 目录前缀，放行该目录及其下全部文件
#   - 含 * 或 ? 的模式按 glob：** 跨目录任意层；* 单个路径段；? 单字符
#   - 目标文件在仓库根之外时，只有绝对路径模式可能放行，否则拒绝
#
# 安全策略：
#   - 守卫未接线（allowed 与敏感清单都没配置）→ 放行，不干扰日常手动使用
#   - 已配置 allowed 但范围为空（[] / 空文件）→ 拒绝一切写入
#   - 敏感清单命中 → 无论 allowed_paths 是否覆盖，一律拒绝（防密钥泄漏）
#   - Bash 命令解析不出写入目标或含高危模式 → 保守拒绝（fail-closed）
#   - node 不可用 → 拒绝（宁可拦截不可放行越界，fail-closed）
#
# 依赖：bash + node。机器上必有 node：AI SDLC 系统自身是 Node 工程，
# Claude Code CLI 亦基于 Node。
# ============================================================

set -u

# ============================================================
# 无人值守门控（廉价短路：先于 node 启动与临时文件写入）
#
# 本守卫只服务于「Supervisor 无人值守派发 Worker」这一场景。人工交互式会话下，每次
# Bash/Read/Grep/Write/Edit 都拉起一次 node（还要先写 ~33KB 临时 .cjs）只为得知"没接线"，
# 这份开销白付。故在最前面用纯 shell 判一次，非无人值守直接退 0，完全不进 node 校验。
#
# 判定口径（只看环境变量，不做任何 IO）：
#   1) SDLC_UNATTENDED 取显式关闭值（0/false/off/no，大小写不敏感）-> 关闭
#      （人工会话里哪怕残留了 SDLC_* 也能一键排除干扰）
#   2) 三个接线变量全空（SDLC_ALLOWED_PATHS / SDLC_ALLOWED_PATHS_FILE 指向的路径
#      不存在 / SDLC_SENSITIVE_PATH_PATTERNS）-> 视为未接线 -> 关闭
#
# 注：这是"门控"而非"新增必填开关"——未显式设置 SDLC_UNATTENDED 时一律按接线变量
# 推断，只注入 SDLC_ALLOWED_PATHS 的既有 Supervisor 版本行为不变；下面 node 内的
# armed 判定原样保留，作为第二道保险。
# ============================================================
case "${SDLC_UNATTENDED:-}" in
  0 | [Ff][Aa][Ll][Ss][Ee] | [Oo][Ff][Ff] | [Nn][Oo]) exit 0 ;;
esac

if [ -z "${SDLC_ALLOWED_PATHS:-}" ] &&
  [ -z "${SDLC_SENSITIVE_PATH_PATTERNS:-}" ] &&
  [ ! -e "${SDLC_ALLOWED_PATHS_FILE:-}" ]; then
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  # fail-closed：没有运行时无法校验，拦截所有写工具并说明原因
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"路径守卫缺少 node 运行时，无法执行路径校验，已拒绝本次操作"}}'
  exit 2
fi

# 逻辑全部放在 node 内执行：stdin 原样透传给 node（hook JSON 不落地、不走参数，
# 规避 JSON 转义问题）。node 代码以 here-doc 写进 hook 同目录的临时 .js，再 `node <file>`
# 执行——**不用 node -e**：内联程序超过 Windows ~32K 命令行上限（CreateProcess 32767 字符）
# 会直接 spawn 失败 exit 126（本守卫 JS 已 ~33KB）。Git Bash 下用 cygpath -w 把临时文件
# 路径转成 Windows 原生路径，保证 Windows 版 node.exe 能读到。临时文件退出即清理。
guard_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
guard_tmp_js="$guard_dir/.guard-node-$$.cjs"
guard_js="$guard_tmp_js"
if command -v cygpath >/dev/null 2>&1; then
  guard_js=$(cygpath -w "$guard_tmp_js" 2>/dev/null || printf '%s' "$guard_tmp_js")
fi
cleanup_guard_tmp() { rm -f "$guard_tmp_js"; }
trap cleanup_guard_tmp EXIT
cat > "$guard_tmp_js" <<'NODE'
const fs = require("fs");
const path = require("path");

const debug = process.env.SDLC_PATH_GUARD_DEBUG === "1";
const log = (m) => { if (debug) console.error("[path-guard] " + m); };

// ---- 解析 hook 输入（stdin JSON：tool_name / tool_input / cwd）----
let hook = {};
try {
  hook = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
} catch (e) {
  log("hook JSON 解析失败: " + e.message);
}

const toolName = hook.tool_name || "";
const ti = hook.tool_input || {};

// 写类工具：校验文件路径是否在 allowed 范围内（原守卫职责）
const WRITE_TOOLS = ["Write", "Edit", "MultiEdit", "NotebookEdit"];
// 读类工具：内容会进 transcript，只做敏感文件拦截，不套 allowed 写范围
const READ_TOOLS = ["Read", "Grep"];

// ---- 路径归一 / 仓库内判定 ----
const repoRoot = path.resolve(process.env.SDLC_REPO_ROOT || hook.cwd || process.cwd());
const norm = (s) => s.replace(/\\/g, "/");
const withSlash = (s) => (s.endsWith("/") ? s : s + "/");

function analyze(absPath) {
  const target = path.isAbsolute(absPath)
    ? path.resolve(absPath)
    : path.resolve(repoRoot, absPath); // 相对路径一律相对仓库根，不依赖进程 cwd
  const t = norm(target);
  const rootN = withSlash(norm(repoRoot));
  const inside = t === rootN.slice(0, -1) || t.indexOf(rootN) === 0;
  const rel = inside ? norm(path.relative(repoRoot, target)) : "";
  return { inside, rel, abs: t };
}

// Windows 文件系统不区分大小写，默认忽略大小写以免误拒；可经 env 显式覆盖
const ci =
  process.env.SDLC_PATH_GUARD_CASE_INSENSITIVE === "1" || process.platform === "win32";
const eq = (a, b) => (ci ? a.toLowerCase() === b.toLowerCase() : a === b);
const startsWith = (a, p) =>
  ci ? a.toLowerCase().startsWith(p.toLowerCase()) : a.startsWith(p);

// glob -> RegExp：** 跨目录，* 单路径段，? 单字符，其余字符按字面
function globToRegExp(glob) {
  let re = "";
  let i = 0;
  while (i < glob.length) {
    const c = glob.charAt(i);
    if (c === "*") {
      if (glob.charAt(i + 1) === "*") {
        i += 2;
        if (glob.charAt(i) === "/") {
          re += "(?:[^/]+/)*"; // **/ ：零到多层目录
          i += 1;
        } else {
          re += ".*";
        }
      } else {
        re += "[^/]*";
        i += 1;
      }
    } else if (c === "?") {
      re += "[^/]";
      i += 1;
    } else if ("\\^$.|+()[]{}".indexOf(c) !== -1) {
      re += "\\" + c;
      i += 1;
    } else {
      re += c;
      i += 1;
    }
  }
  return new RegExp("^" + re + "$", ci ? "i" : "");
}

function matchOne(target, pat) {
  const p = norm(pat);
  if (eq(p, target)) return true; // 精确文件
  if (p.charAt(p.length - 1) === "/") {
    // 目录前缀：以 / 结尾的模式放行其下所有文件
    const base = p.slice(0, -1);
    if (eq(target, base) || startsWith(target, withSlash(base))) return true;
  }
  if (p.indexOf("*") !== -1 || p.indexOf("?") !== -1) return globToRegExp(p).test(target);
  return false;
}

function matchesAny(target, pats) {
  return pats.some((p) => matchOne(target, p));
}

// 收集 glob 清单（env JSON 数组 或 每行一个 glob）
function readPatternList(raw) {
  if (raw == null) return [];
  const v = String(raw).trim();
  if (v === "") return [];
  if (v.charAt(0) === "[") {
    try {
      const arr = JSON.parse(v);
      if (Array.isArray(arr)) return arr.map(String).map((s) => s.trim()).filter(Boolean);
    } catch (e) {
      log("不是合法 JSON 数组: " + e.message);
      return [];
    }
  }
  return v.split(/\r?\n/).map((s) => s.trim()).filter((s) => s.length > 0 && s.charAt(0) !== "#");
}

// ============================================================
// 规则 0：开关判定 —— 守卫未接线则放行（不干扰人工手动跑 claude）
// ============================================================
const allowedEnv = process.env.SDLC_ALLOWED_PATHS;
const allowedEnvArmed = allowedEnv != null && String(allowedEnv).trim() !== "";
const allowedFileEnv = process.env.SDLC_ALLOWED_PATHS_FILE;
const allowedFileArmed = allowedFileEnv != null && fs.existsSync(allowedFileEnv);
const allowedArmed = allowedEnvArmed || allowedFileArmed;

const sensEnvRaw = process.env.SDLC_SENSITIVE_PATH_PATTERNS;
const sensExplicit = sensEnvRaw != null && String(sensEnvRaw).trim() !== "";

const armed = allowedArmed || sensExplicit;
if (!armed) {
  log("守卫未启用：未配置 SDLC_ALLOWED_PATHS / SDLC_ALLOWED_PATHS_FILE / SDLC_SENSITIVE_PATH_PATTERNS");
  process.exit(0);
}

// ---- allowed 清单 ----
const rawPatterns = [];
if (allowedEnvArmed) {
  const v = String(allowedEnv).trim();
  if (v.charAt(0) === "[") {
    const arr = readPatternList(v);
    rawPatterns.push(...arr);
  } else {
    rawPatterns.push(...v.split(/\r?\n/));
  }
}
if (allowedFileArmed) {
  const text = fs.readFileSync(allowedFileEnv, "utf8");
  for (const line of text.split(/\r?\n/)) {
    const s = line.trim();
    if (s.length > 0 && s.charAt(0) !== "#") rawPatterns.push(s);
  }
}
const patterns = rawPatterns.map((s) => String(s).trim()).filter((s) => s.length > 0);
log("allowed_patterns = " + JSON.stringify(patterns));

// ---- 敏感文件清单（独立于 allowed_paths 的硬性规则）----
const DEFAULT_SENSITIVE = [
  "**/.env*",           // .env / .env.local / .env.example / .env.sdlc …隐藏环境变量文件
  "**/*.env",           // prod.env 等以 .env 结尾的文件
  "**/*.pem",           // 私钥 / 证书
  "**/*.p12",
  "**/*.pfx",
  "**/.ssh/**",         // ssh 私钥目录
  "**/id_rsa*",
  "**/id_ed25519*",
  "**/*secret*",        // 路径含 secret（secrets.json 等）——子串匹配，见头部注释
  "**/*credentials*",   // 路径含 credential(s)——子串匹配，可能误伤命名文件，可配置收窄
];
const sensitivePatterns = sensExplicit
  ? readPatternList(sensEnvRaw)
  : DEFAULT_SENSITIVE.slice();
log("sensitive_patterns = " + JSON.stringify(sensitivePatterns));

// ============================================================
// 拒绝出口：统一 exit 2 + stdout deny JSON
// ============================================================
function deny(reason) {
  log("DENY  -> " + toolName + " :: " + reason.split("\n")[0]);
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    }) + "\n"
  );
  process.exit(2);
}

// ---- 敏感文件命中判定（rel 与 abs 都测，覆盖仓库内外）----
function sensitiveHit(candPath) {
  const a = analyze(candPath);
  const candidates = [];
  if (a.rel) candidates.push(a.rel);
  candidates.push(a.abs);
  for (const target of candidates) {
    for (const pat of sensitivePatterns) {
      if (matchOne(target, pat)) return { path: target, pattern: pat };
    }
  }
  return null;
}

function sensitiveReason(hit, verb) {
  return (
    "目标命中敏感文件清单（防密钥泄漏进 transcript/stop-hook），禁止" + verb + "\n" +
    "  工具: " + toolName + "\n" +
    "  路径: " + hit.path + "\n" +
    "  命中模式: " + hit.pattern +
    "\n此类文件含真实密钥/凭据值，Worker 升级/审查/重构无需接触其内容；确需操作请停下并在输出中说明。"
  );
}

// ---- allowed 写范围判定（复用原守卫语义）----
function scopeCheck(candPath) {
  const a = analyze(candPath);
  let ok = false;
  for (const pat of patterns) {
    const p = norm(pat);
    const isAbsPattern = p.charAt(0) === "/" || /^[A-Za-z]:\//.test(p);
    if (!a.inside && !isAbsPattern) continue; // 仓库外文件只能被绝对路径模式放行
    const target = isAbsPattern ? a.abs : a.rel;
    if (target.length === 0) continue;
    if (matchOne(target, p)) {
      ok = true;
      break;
    }
  }
  return ok;
}

// ---- 完成信号结果文件豁免（M1.5）----
// SDLC_RESULT_FILE 指明的**确切**路径是 allowed_paths 外唯一合法写入（DEVELOPER
// 把 docs/tasks/<taskCode>.result.json 作为完成信号交给 supervisor，见 workerReport.ts）。
// 相对值按仓库内 rel 比较、绝对值按 abs 比较；只放行该单一路径，docs/tasks/ 下其它文件不豁免。
const resultFileRaw = process.env.SDLC_RESULT_FILE
  ? String(process.env.SDLC_RESULT_FILE).trim()
  : "";
const resultFileArmed = resultFileRaw !== "";
function isResultFileWrite(candPath) {
  if (!resultFileArmed) return false;
  const a = analyze(candPath);
  const r = analyze(resultFileRaw);
  if (a.rel && r.rel && eq(a.rel, r.rel)) return true;
  return eq(a.abs, r.abs);
}

// ============================================================
// 规则 2：Bash 静态分析
//   - 高危命令黑名单（与路径无关，无条件拒绝）
//   - 敏感文件引用（读取/写入路径命中敏感清单）
//   - 写入目标解析 + 范围校验；解析不出 => 保守拒绝
// ============================================================

// 简易 shell 分词（去掉引号/转义，按空白分段；不保留引号，用于动词取操作数）
function wordTokens(cmd) {
  const toks = [];
  let i = 0;
  const n = cmd.length;
  while (i < n) {
    const c = cmd.charAt(i);
    if (/\s/.test(c)) { i++; continue; }
    let s = "";
    let inQ = null;
    while (i < n && !/[\s]/.test(cmd.charAt(i))) {
      const ch = cmd.charAt(i);
      if (ch === "\\" && i + 1 < n) { s += cmd.charAt(i + 1); i += 2; continue; }
      if (inQ) {
        if (ch === inQ) { inQ = null; i++; continue; }
        s += ch; i++; continue;
      }
      if (ch === "'" || ch === '"') { inQ = ch; i++; continue; }
      s += ch; i++;
    }
    if (s.length > 0) toks.push(s);
  }
  return toks;
}

// 把命令在 shell 运算符处切成多段，避免 `rm a && echo hi` 把 hi 当 rm 操作数
function segmentsOf(cmd) {
  const segs = [];
  let cur = "";
  let i = 0;
  const n = cmd.length;
  let inQ = null;
  while (i < n) {
    const c = cmd.charAt(i);
    if (inQ) {
      if (c === inQ) inQ = null;
      cur += c; i++; continue;
    }
    if (c === "'" || c === '"') { inQ = c; cur += c; i++; continue; }
    if (c === "\\") { cur += c; if (i + 1 < n) { cur += cmd.charAt(i + 1); i += 2; } else i++; continue; }
    if (c === "&" && cmd.charAt(i + 1) === "&") { segs.push(cur); cur = ""; i += 2; continue; }
    if (c === "|" && cmd.charAt(i + 1) === "|") { segs.push(cur); cur = ""; i += 2; continue; }
    if (c === "|" || c === ";" || c === "\n") { segs.push(cur); cur = ""; i++; continue; }
    cur += c; i++;
  }
  segs.push(cur);
  return segs.filter((s) => s.trim().length > 0);
}

// 高危（与路径无关）命令黑名单。命中返回 {desc}，否则 null。
function hardBlock(cmd) {
  const L = " " + cmd.toLowerCase() + " ";
  const hits = [
    { re: /[^a-z0-9]git[ \t]+(push|clone)\b/, desc: "git push/clone（推送/克隆，改变远端或新建远程仓库）" },
    { re: /[^a-z0-9]git[ \t]+remote[ \t]+(add|set-url|remove|rename|update)\b/, desc: "git remote 修改远端配置" },
    { re: /[^a-z0-9]git[ \t]+reset[ \t]+--hard\b/, desc: "git reset --hard（丢弃工作区改动）" },
    { re: /[^a-z0-9]git[ \t]+clean\b/, desc: "git clean（删除未跟踪文件）" },
    { re: /[^a-z0-9](chmod|chown|chgrp)\b/, desc: "chmod/chown/chgrp（改文件属性/属主）" },
    { re: /[^a-z0-9](curl|wget)\b[^|;]*\|\s*(sudo\s+)?(sh|bash|zsh|dash)\b/, desc: "下载即执行 curl|sh / wget|sh" },
    { re: /[^a-z0-9](base64|xxd)[ \t]+-[a-z]*d?[ \t]+[^|;]*\|\s*(sudo\s+)?(sh|bash|zsh|dash)\b/, desc: "解码即执行 base64 -d|sh 类" },
  ];
  for (const h of hits) {
    if (h.re.test(L)) return { desc: h.desc };
  }
  return null;
}

// 命令里是否含不可静态解析的内联代码执行（其内部可做任意写入，无法用静态分析覆盖）
function opaqueEval(cmd) {
  const L = " " + cmd.toLowerCase() + " ";
  const re =
    /[^a-z0-9]node\s+-[a-z]*e\b|[^a-z0-9](python|python2|python3|perl|ruby)\s+-[a-z]*[cre]\b|[^a-z0-9]php\s+-r\b|[^a-z0-9]eval\b|[^a-z0-9](sh|bash|zsh|dash)\s+-c\b/;
  const m = L.match(re);
  if (m) return m[0].trim().split(/\s+/)[0] || "内联代码";
  return null;
}

// 扫描重定向 >/>>/&>/2> 的目标文件；返回 { files:[], opaque:bool }
// 过滤 /dev/null / NUL（仅丢输出，非真实写文件）；2>&1、&2、&- 这类 fd 复制忽略。
function scanRedirects(cmd) {
  const files = [];
  let opaque = false;
  let i = 0;
  const n = cmd.length;
  while (i < n) {
    const c = cmd.charAt(i);
    if (c === "'" || c === '"') {
      const q = c; i++;
      while (i < n && cmd.charAt(i) !== q) i++;
      i++; continue;
    }
    if (c === "\\") { i += 2; continue; }
    // 算术/参数/条件表达式里的 > 不是重定向，跳过整段避免误判
    if (
      (c === "$" && cmd.charAt(i + 1) === "(" && cmd.charAt(i + 2) === "(") ||
      (c === "(" && cmd.charAt(i + 1) === "(")
    ) {
      let d = 1;
      let j = i + (c === "$" ? 3 : 2);
      while (j < n) {
        if (cmd.charAt(j) === "(") d++;
        else if (cmd.charAt(j) === ")") { d--; if (d === 0) { j++; break; } }
        j++;
      }
      i = j; continue;
    }
    if (c === "$" && cmd.charAt(i + 1) === "{") { i = skipNoExec(cmd, i); continue; }
    if (c === "[" && cmd.charAt(i + 1) === "[") {
      let j = i + 2;
      while (j + 1 < n && !(cmd.charAt(j) === "]" && cmd.charAt(j + 1) === "]")) j++;
      i = Math.min(n, j + 2); continue;
    }
    if (c === ">") {
      let j = i + 1;
      if (cmd.charAt(j) === ">") j++;      // >>
      if (cmd.charAt(j) === "|") j++;      // >|（noclobber 绕过）
      while (j < n && /\s/.test(cmd.charAt(j))) j++;
      // 进程替换重定向 > >(cmd)：目标不是文件，其内命令由区域拆解单独校验
      if (cmd.charAt(j) === ">" && cmd.charAt(j + 1) === "(") {
        i = scanUnit(cmd, j + 1);
        continue;
      }
      // fd 复制：>&1 / >&2 / >&- 不产生新文件
      if (cmd.charAt(j) === "&") {
        const nx = cmd.charAt(j + 1);
        if (nx === "-" || /[0-9]/.test(nx)) { i = j + 2; continue; }
      }
      if (cmd.charAt(j) === "$" || cmd.charAt(j) === "`") {
        opaque = true; i = j + 1; continue; // 目标来自命令/变量替换，解析不出
      }
      // 读目标 token（可带引号）
      let tok = "";
      if (cmd.charAt(j) === "'" || cmd.charAt(j) === '"') {
        const q = cmd.charAt(j); j++;
        while (j < n && cmd.charAt(j) !== q) { tok += cmd.charAt(j); j++; }
        j++;
      } else {
        while (j < n && !/[\s&|;<>()`]/.test(cmd.charAt(j))) { tok += cmd.charAt(j); j++; }
      }
      i = j;
      tok = tok.trim();
      if (!tok) { opaque = true; continue; }
      const low = tok.toLowerCase();
      if (low === "/dev/null" || low === "nul" || low === "nul:") continue; // 丢弃输出
      files.push(tok);
      continue;
    }
    i++;
  }
  return { files, opaque };
}

// 分析一条 Bash 命令。返回 { denied } | { targets:[], ambiguous:false }
// targets 里的元素为待范围校验的路径 token（可能相对/绝对，含未展开的变量或通配符）。
function analyzeBash(cmd) {
  // 1) 内联代码执行 -> 无法静态分析其写入，保守拒绝（高危黑名单已在主流程前置判定）
  const evalHit = opaqueEval(cmd);
  if (evalHit) {
    return {
      denied: {
        kind: "ambiguous",
        desc:
          "命令含不可静态解析的内联代码执行（" + evalHit + "），无法确认其不会越界写入，保守拒绝（§9.3 非完整沙箱）",
      },
    };
  }

  const targets = [];
  let ambiguous = null;
  const segs = segmentsOf(cmd);

  // 3) 重定向目标（全命令扫描）
  const rd = scanRedirects(cmd);
  if (rd.opaque) ambiguous = "存在无法静态解析目标的重定向（> $(...) / 变量 / 反引号）";
  for (const f of rd.files) targets.push(f);

  for (const seg of segs) {
    const toks = wordTokens(seg);
    // 找动词（仅当它作为独立命令首词出现，避免匹配路径里的同名片段）
    const findVerb = (v) => {
      for (let k = 0; k < toks.length; k++) if (toks[k] === v) return k;
      return -1;
    };
    const isOptOrAssign = (t) => t.startsWith("-") || t.indexOf("=") !== -1;
    const operandsAfter = (idx) => {
      // 该段内动词之后的非选项操作数（段内已无 &&/||/;/|）
      const out = [];
      for (let k = idx + 1; k < toks.length; k++) {
        if (isOptOrAssign(toks[k])) continue;
        out.push(toks[k]);
      }
      return out;
    };

    // tee：后面的第一个文件操作数是写目标
    let vi = findVerb("tee");
    if (vi >= 0) {
      const ops = operandsAfter(vi);
      if (ops.length > 0) targets.push(ops[0]);
    }

    // sed -i：跳过 -i/-e/-n 等选项后，把"带 / 的表达式"跳过，剩下的即为要改的文件
    vi = findVerb("sed");
    if (vi >= 0 && toks.slice(vi + 1).some((t) => t === "-i" || t.startsWith("-i"))) {
      const rest = toks.slice(vi + 1).filter((t) => !t.startsWith("-"));
      if (rest.length > 0 && rest[0].indexOf("/") !== -1) rest.shift(); // 表达式如 s/a/b/
      if (rest.length > 0) targets.push(...rest);
      else ambiguous = "sed -i 但无法识别其要修改的文件操作数";
    }

    // cp / mv / install：目标是"最后一个操作数"；-t DIR 时目标是 DIR（目录）
    for (const v of ["cp", "mv", "install"]) {
      vi = findVerb(v);
      if (vi < 0) continue;
      let dest = null;
      let destIsDir = false;
      const sources = [];
      for (let k = vi + 1; k < toks.length; k++) {
        const t = toks[k];
        if (t === "-t") { dest = toks[k + 1] || null; destIsDir = true; k++; continue; }
        if (isOptOrAssign(t)) continue;
        sources.push(t);
      }
      if (dest == null) dest = sources.pop() || null; // 常规：最后一个是目标
      if (dest == null) { ambiguous = v + " 未能解析目标路径"; continue; }
      const isDir = destIsDir || dest.charAt(dest.length - 1) === "/";
      if (isDir) {
        // 目录目标：单源（非目录/非 glob）可推导落点文件名；否则无法静态确定
        const src = sources.length === 1 ? sources[0] : null;
        if (src && !/[*?]/.test(src) && src.charAt(src.length - 1) !== "/") {
          targets.push(dest + src.split("/").pop());
        } else {
          ambiguous = v + " 目标为目录且源不确定（多源/目录源/glob），无法静态确定写入的具体文件";
        }
      } else if (sources.length > 0) {
        targets.push(dest); // 文件目标
      }
    }

    // rm：操作数即删除目标；根/家目录删除无条件拒绝；其余按范围校验
    vi = findVerb("rm");
    if (vi >= 0) {
      const ops = operandsAfter(vi);
      if (ops.length === 0) continue;
      for (const o of ops) {
        if (o === "." || o === ".." || o === "~" || o.startsWith("~/") || o === "/" || /^\/[A-Za-z0-9]/.test(o)) {
          return { denied: { kind: "hard", desc: "rm 指向根目录/家目录/当前目录（" + o + "），禁止整树删除" } };
        }
        targets.push(o);
      }
    }

    // touch / truncate：第一个操作数是要创建/截断的文件
    for (const v of ["touch", "truncate"]) {
      vi = findVerb(v);
      if (vi >= 0) {
        const ops = operandsAfter(vi);
        if (ops.length > 0) targets.push(ops[0]);
      }
    }

    // dd：of= 是写目标
    for (const t of toks) {
      if (t.startsWith("of=") && t.length > 3) targets.push(t.slice(3));
    }
  }

  // 解析不出的写入隐患 -> 保守拒绝
  if (ambiguous) return { denied: { kind: "ambiguous", desc: ambiguous } };

  // 目标 token 里混入变量/通配符/命令替换的，无法确认实际文件 -> 保守拒绝
  for (const t of targets) {
    if (t.indexOf("$") !== -1 || t.indexOf("`") !== -1) {
      return { denied: { kind: "ambiguous", desc: "写入目标含变量/命令替换（" + t + "），无法静态确认，保守拒绝" } };
    }
    if (t.indexOf("*") !== -1 || t.indexOf("?") !== -1) {
      return { denied: { kind: "ambiguous", desc: "写入目标含通配符（" + t + "），无法静态确认展开结果，保守拒绝" } };
    }
  }

  // 去重后交给范围校验
  const uniq = [];
  for (const t of targets) if (!uniq.includes(t)) uniq.push(t);
  return { targets: uniq };
}

// 把 Bash 命令里的"路径样" token 挑出来做敏感命中判定（防止把 grep 的模式词当路径）
function bashPathLikeTokens(cmd) {
  const out = [];
  for (const seg of segmentsOf(cmd)) {
    for (const t of wordTokens(seg)) {
      if (t.startsWith("-")) continue;
      if (/^[A-Za-z0-9_]+=/.test(t)) continue; // 环境变量赋值，非路径
      // 只挑"看起来像文件/路径"的 token：带分隔符/以 ~、. 开头/含点号，或已知敏感文件名
      const base = t.split("/").pop() || t;
      const looksLikePath =
        t.indexOf("/") !== -1 || t.startsWith("~") || t.startsWith(".") || t.indexOf(".") !== -1;
      const knownName = /^(id_rsa|id_ed25519|id_dsa|id_ecdsa)(\.pub)?$/i.test(base);
      const extLike = /\.(env|pem|p12|pfx|key|p8|cer|crt)$/i.test(base);
      if (looksLikePath || knownName || extLike) out.push(t);
    }
  }
  return out;
}

// ============================================================
// 复合命令拆解：一条 Bash 命令里的 &&、;、|、|| 已在 analyzeBash 里按段分别校验；
// 这里再补最后一类漏网之鱼——藏在 $()、反引号、子 shell(...)、进程替换 <(...)/>(...)
// 里的"可执行内容"。它们即使外层命令看起来安全也会真正执行写入，因此要把这些内层
// 文本提出来当独立子命令再做一遍校验；只要任一子命令越界/解析不出目标就整条拒绝。
// 单引号内、双引号内的纯字面文本、$(( 算术 )) 不执行，不拆。
// ============================================================

// 从 s[i] 开始扫描"一个执行单元"并返回其后的下标：单引号串、双引号串（内部仍会
// 出现 $()/反引号并按其嵌套平衡跳过）、反引号串、$() 命令替换、() 子 shell 分组。
function scanUnit(s, i) {
  const c = s.charAt(i);
  if (c === "'") {
    const e = s.indexOf("'", i + 1);
    return e === -1 ? s.length : e + 1;
  }
  if (c === '"') {
    let j = i + 1;
    while (j < s.length) {
      const ch = s.charAt(j);
      if (ch === "\\") { j += 2; continue; }
      if (ch === '"') return j + 1;
      if (ch === "$" && s.charAt(j + 1) === "(") { j = scanUnit(s, j); continue; }
      if (ch === "`") { j = scanUnit(s, j); continue; }
      j++;
    }
    return s.length;
  }
  if (c === "`") {
    let j = i + 1;
    while (j < s.length) {
      if (s.charAt(j) === "\\") { j += 2; continue; }
      if (s.charAt(j) === "`") return j + 1;
      j++;
    }
    return s.length;
  }
  if ((c === "$" && s.charAt(i + 1) === "(") || c === "(") {
    // $（ ... ） 或 （ ... ）：按嵌套括号 + 引号/反引号平衡找匹配
    let j = i + (c === "$" ? 2 : 1);
    let depth = 1;
    while (j < s.length) {
      const ch = s.charAt(j);
      if (ch === "\\") { j += 2; continue; }
      if (ch === "'" || ch === '"' || ch === "`") { j = scanUnit(s, j); continue; }
      if (ch === "(") { depth++; j++; continue; }
      if (ch === ")") { depth--; if (depth === 0) return j + 1; j++; continue; }
      j++;
    }
    return s.length;
  }
  return i + 1;
}

// 跳过不执行命令的内容：$(( 算术 )) / (( 算术 )) / ${ 参数展开 }，返回结束下标
function arithmeticEnd(s, i) {
  // 从开头的 (（或 $ 后紧跟 ((）找配对的 ))，返回其后的下标
  let j = i + (s.charAt(i) === "$" ? 3 : 2);
  let d = 1;
  while (j < s.length) {
    if (s.charAt(j) === "(") d++;
    else if (s.charAt(j) === ")") { d--; if (d === 0) return j + 1; }
    j++;
  }
  return s.length;
}
function skipNoExec(s, i) {
  if (s.charAt(i) === "$" && s.charAt(i + 1) === "(" && s.charAt(i + 2) === "(") {
    return arithmeticEnd(s, i);
  }
  if (s.charAt(i) === "(" && s.charAt(i + 1) === "(") {
    return arithmeticEnd(s, i);
  }
  if (s.charAt(i) === "$" && s.charAt(i + 1) === "{") {
    let j = i + 2;
    while (j < s.length) {
      const ch = s.charAt(j);
      if (ch === "\\") { j += 2; continue; }
      if (ch === "'" || ch === '"') { j = scanUnit(s, j); continue; }
      if (ch === "}") return j + 1;
      j++;
    }
    return s.length;
  }
  return i + 1;
}

// 从双引号串内部收集其中仍会执行的 $()/反引号（普通文本不执行，跳过），返回结束下标
function scanDoubleCapturing(s, i, regions) {
  let j = i + 1;
  while (j < s.length) {
    const ch = s.charAt(j);
    if (ch === "\\") { j += 2; continue; }
    if (ch === '"') return j + 1;
    if (ch === "$" && s.charAt(j + 1) === "(") {
      const end = scanUnit(s, j);
      const inner = s.slice(j + 2, end - 1);
      regions.push(inner);
      regions.push(...extractExecRegions(inner));
      j = end; continue;
    }
    if (ch === "`") {
      const end = scanUnit(s, j);
      const inner = s.slice(j + 1, end - 1);
      regions.push(inner);
      regions.push(...extractExecRegions(inner));
      j = end; continue;
    }
    j++;
  }
  return s.length;
}

// 返回命令里所有"嵌套可执行区域"的文本（不含整条命令本身）
function extractExecRegions(s) {
  const regions = [];
  let i = 0;
  while (i < s.length) {
    const c = s.charAt(i);
    if (c === "'") { i = scanUnit(s, i); continue; }          // 单引号：纯字面
    if (c === "\\") { i += 2; continue; }
    if (c === '"') { i = scanDoubleCapturing(s, i, regions); continue; }
    if (c === "$" && s.charAt(i + 1) === "{") { i = skipNoExec(s, i); continue; }
    if (c === "$" && s.charAt(i + 1) === "(" && s.charAt(i + 2) === "(") { i = skipNoExec(s, i); continue; }
    if (c === "(" && s.charAt(i + 1) === "(") { i = skipNoExec(s, i); continue; }
    if (c === "$" && s.charAt(i + 1) === "(") {
      const end = scanUnit(s, i);
      const inner = s.slice(i + 2, end - 1);
      regions.push(inner);
      regions.push(...extractExecRegions(inner));
      i = end; continue;
    }
    if (c === "`") {
      const end = scanUnit(s, i);
      const inner = s.slice(i + 1, end - 1);
      regions.push(inner);
      regions.push(...extractExecRegions(inner));
      i = end; continue;
    }
    if (c === "(") {
      const end = scanUnit(s, i);
      const inner = s.slice(i + 1, end - 1);
      regions.push(inner);
      regions.push(...extractExecRegions(inner));
      i = end; continue;
    }
    if ((c === "<" || c === ">") && s.charAt(i + 1) === "(") {
      // 进程替换 <(cmd) / >(cmd)：内容会执行
      const end = scanUnit(s, i + 1);
      const inner = s.slice(i + 2, end - 1);
      regions.push(inner);
      regions.push(...extractExecRegions(inner));
      i = end; continue;
    }
    i++;
  }
  return regions;
}

// ============================================================
// 主流程：按工具分发
// ============================================================

// ---- 收集"写类"候选路径（Write/Edit/MultiEdit/NotebookEdit）----
function collectPathCandidates() {
  const c = [];
  for (const key of ["file_path", "notebook_path", "path"]) {
    const v = ti[key];
    if (typeof v === "string" && v.length > 0) c.push(v);
    else if (Array.isArray(v)) c.push(...v.filter((x) => typeof x === "string" && x.length > 0));
  }
  return c;
}

// ---- Bash：整条命令 + 每个拆出的子命令分别校验 ----
if (toolName === "Bash") {
  const cmd = ti.command;
  if (typeof cmd !== "string" || cmd.trim().length === 0) {
    deny("Bash 命令为空或无法读取，无法做越界/敏感校验，保守拒绝（§9.3 非完整沙箱）");
  }

  // 复合命令拆解：外层（顶层 &&/;|/|| 由 analyzeBash 内部再按段处理）+ 嵌套可执行
  // 区域（$()/反引号/子 shell/进程替换）。任一子命令命中高危、敏感、越界或解析不出
  // 目标，整条命令即拒绝——不会因第一个子命令"看起来安全"就放行。
  const units = [cmd].concat(extractExecRegions(cmd));
  for (const u of units) {
    if (typeof u !== "string" || u.trim().length === 0) continue;

    // 1) 高危命令黑名单（与 allowed_paths 无关，无条件拒绝）
    const hb = hardBlock(u);
    if (hb) {
      deny(
        "Bash 命令（或其子命令）命中高危操作黑名单，无论 allowed_paths 一律拒绝（§9.3）\n" +
        "  工具: " + toolName + "\n" +
        "  命中: " + hb.desc +
        "\n此类命令超出 Worker 操作边界，Supervisor 侧另有白名单收敛；请停下并在输出中说明。"
      );
    }

    // 2) 敏感文件引用：读取也可能泄漏，先于写范围判定
    for (const tok of bashPathLikeTokens(u)) {
      const hit = sensitiveHit(tok);
      if (hit) deny(sensitiveReason(hit, "访问（读取/写入均拦截）"));
    }

    // 3) 未配置写范围 => 只做上面的敏感/高危拦截，不做越界分析
    if (!allowedArmed) continue;

    const a = analyzeBash(u);
    if (a.denied) {
      const d = a.denied;
      if (d.kind === "hard") {
        deny(
          "Bash 命令（或其子命令）命中高危删除/整树操作，无论 allowed_paths 一律拒绝（§9.3）\n" +
          "  工具: " + toolName + "\n" +
          "  命中: " + d.desc + "\n请停下并在输出中说明。"
        );
      }
      deny(
        "Bash 命令（或其子命令）的写入目标无法可靠静态解析，保守拒绝而非放行（§9.3，非完整沙箱）\n" +
        "  工具: " + toolName + "\n" +
        "  原因: " + d.desc +
        "\n请改用 Write/Edit 等受 allowed_paths 约束的工具，或在输出中说明所需操作。"
      );
    }

    if (!a.targets || a.targets.length === 0) continue;

    const offenders = [];
    for (const t of a.targets) {
      if (isResultFileWrite(t)) {
        log("EXEMPT(result-file) Bash(write) -> " + analyze(t).abs);
        continue; // 完成信号结果文件：allowed 外唯一豁免，仅精确该路径
      }
      const ok = scopeCheck(t);
      const ainfo = analyze(t);
      log((ok ? "ALLOW " : "DENY  ") + "Bash(write) -> " + ainfo.abs);
      if (!ok) offenders.push(t);
    }
    if (offenders.length > 0) {
      const first = offenders[0];
      const reason =
        "Bash 命令（或其子命令）的写入目标不在 Task 允许修改的范围内（PreToolUse 路径守卫，§9.3）\n" +
        "  工具: " + toolName + "\n" +
        "  尝试写入: " + first + "\n" +
        "  允许模式(" + patterns.length + "):\n    - " + patterns.join("\n    - ") +
        "\n请在 allowed_paths 范围内工作；如确需改范围外文件，停下并在输出中说明。";
      deny(reason);
    }
  }

  log("Bash 全部子命令校验通过，放行");
  process.exit(0);
}

// ---- Read/Grep：内容会进 transcript，只做敏感拦截 ----
if (READ_TOOLS.includes(toolName)) {
  for (const cand of collectPathCandidates()) {
    const hit = sensitiveHit(cand);
    if (hit) deny(sensitiveReason(hit, "读取"));
  }
  log(toolName + " 未命中敏感清单，放行");
  process.exit(0);
}

// ---- Write/Edit 类：敏感 + allowed 范围双重校验 ----
if (WRITE_TOOLS.includes(toolName)) {
  const candidates = collectPathCandidates();
  if (candidates.length === 0) {
    // 守卫范围内却拿不到路径（工具输入异常），无法判定则放行、交给上层兜底
    log("未从工具输入中解析到写路径，放行");
    process.exit(0);
  }

  for (const cand of candidates) {
    const hit = sensitiveHit(cand);
    if (hit) deny(sensitiveReason(hit, "写入"));
  }

  if (!allowedArmed) {
    log("Write：未配置 SDLC_ALLOWED_PATHS，仅敏感拦截，放行");
    process.exit(0);
  }

  const offenders = [];
  for (const cand of candidates) {
    if (isResultFileWrite(cand)) {
      log("EXEMPT(result-file) " + toolName + " -> " + analyze(cand).abs);
      continue; // 完成信号结果文件：allowed 外唯一豁免，仅精确该路径
    }
    const ok = scopeCheck(cand);
    const ainfo = analyze(cand);
    log((ok ? "ALLOW " : "DENY  ") + toolName + " -> " + ainfo.abs);
    if (!ok) offenders.push({ cand: cand, abs: ainfo.abs });
  }

  if (offenders.length === 0) { log("全部放行"); process.exit(0); }

  const first = offenders[0];
  const reason =
    "路径不在 Task 允许修改的范围内（PreToolUse 路径守卫，§9.3）\n" +
    "  工具: " + toolName + "\n" +
    "  尝试写入: " + first.cand + "\n" +
    "  允许模式(" + patterns.length + "):\n    - " + patterns.join("\n    - ") +
    "\n请在 allowed_paths 范围内工作；如确需改范围外文件，停下并在输出中说明。";
  deny(reason);
}

// 其余（matcher 扩展可能带进来的工具）无针对规则 -> 放行
log("工具 " + toolName + " 无针对规则，放行");
process.exit(0);
NODE
node "$guard_js"
guard_node_exit=$?
rm -f "$guard_tmp_js"
trap - EXIT
exit $guard_node_exit
