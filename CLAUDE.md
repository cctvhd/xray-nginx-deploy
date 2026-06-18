# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

## 项目当前状态（2026-06-18，commit ebbe261）

### 已完成
- `modules/naive.sh`：Caddyfile 禁 h3（`servers { protocols h1 h2 }`）、证书直引用 letsencrypt、certaccess 组权限、certbot hook 改 reload
- `modules/nginx.sh`：`generate_cf_realip_conf()` 补 `is_media_ext` + `redirect_to_fake` map；xhttp/gRPC server block webroot 改为 `/var/www/${DOMAIN}`，`if ($from_cf = 0)` 改为 `if ($redirect_to_fake)`；生成时自动 `mkdir` 并复制 `index.html`
- `modules/xray.sh`：Reality dest 防偷流量（有域名 → nginx 8321，无域名 → dokodemo 4431）；xhttp-reality 防偷流量（dokodemo 4432）
- `.gitignore`：补充排除 `.claude/` 和 `.understand-anything/`

### 待续任务
1. **`generate_fake_site()`**：改为欧洲档案馆主题完整 HTML（与现部署一致），去掉大媒体文件引用，改用脚本从 `/var/www/Example/` 或远程下载
2. **媒体文件打包**：将 `/var/www/Example/` 下的 mp3/mp4 压缩后随仓库分发（或提供下载脚本），供下次部署时自动拉取
3. **North America 模板命名**：`/var/www/Example/North America/` 下的 HTML 文件名硬编码（`cia_index.html`、`la_index.html`），决定是否统一改为 `index.html` 或按域名动态命名
4. **Reality dest 8321 webroot**：`/var/www/${REALITY_DOMAIN}/` 目前脚本只建目录不写 index.html，需要与 generate_fake_site 对齐

### 严格禁止事项
- **永远不要** `git add`、`git commit`、`git push` `server-audit/` 目录下的任何文件
- `server-audit/` 包含服务器敏感审计数据，必须始终保持在 `.gitignore` 中
- 执行任何 git 操作前，先确认 `server-audit/` 不在暂存区
