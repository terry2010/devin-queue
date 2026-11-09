# 审计 03：自查轮、断点续跑、日志与文档一致性

对象：`run-queue.sh` **当前工作区版本（272 行）** + `README.md`。注意：本版已落实模块 1 的 H1/H2/M1 修复（`{ exec; } 2>/dev/null`、`devin </dev/null 9<&-`、`devin -r $SID` 会话链、type-ahead 排空、confirm tty 守卫、QUEUE_TRUST 多值、retry 独立 stats 行），本审计针对新代码。

验证方式：逐行审查 + 实测 `devin list --format json` 输出结构、真实 logs 产物（`session.ids`/`export-*.json`/`step-*.out`/`stats.jsonl`）、`git diff` 新旧版本差异。

## Med

| 级别 | 行号 | 问题 | 建议 |
|---|---|---|---|
| med | 166–172, 202–205 | SID 经 `devin list` "本目录最近活跃"抓取：首步建会话前失败 → 抓成外来会话并被 `-r` 钉死全程；抓取瞬间并发会话更新 → 同错 | 从本步 `export-$label.json` 读 `session_id`（实测顶层有该字段），与本步一一对应、零竞态 |
| med | 87 | `LAST_RUN` 用 `[ -f done.steps ]` 存在性判断：空 done.steps（启动即崩的 run）遮蔽更早可续 run → 进度丢失报"从头执行" | 改 `[ -s "$d/done.steps" ]` 非空判断 |
| med | 87–88, 175–178 | done.steps/session.ids 跨 prompts 目录碰撞（模块 2 M1 未修且放大）：误跳过 + `-r` 钉进别目录的会话 | LOGDIR 记录 `$PROMPTS` 路径，resume 只接受匹配 run |
| med | 175–178, 228 | `awk 'END{print $2}'` 全局取最后一行：--fresh 续跑时早前组待跑步骤被钉进末组会话 | 按组匹配：`$1==n"-start"` 对应行的 SID |
| med | 182, 227–228 | `-r $SID` 目标已删/被锁时无熔断，全队以同一错误逐步失败、SID 永不重抓 | `-r` 失败时 `SID=""` 回退新会话或中止提示 |
| med | 237, 243 | `grep -q "TASK_N_DONE"` 未锚定，正文引用该短语即假阳性 pass 跳过催办 | `grep -qx 'TASK_N_DONE'` 或只查末行 |

- **M3-1**：旧 `-c` 每步重新猜可能自愈，`-r` 是 sticky 的——错接一次污染全程且更隐蔽。export 文件里的 `session_id` 是本步自身的确定性来源，替代 `devin list` 可根除。
- **M3-4**：`session.ids` 为 `label SID` 逐行格式（`1-start A`、`2-start B`、…），已具备按组精确匹配的信息，只是取数方式用错了。
- **M3-6**：实测 `step-1-check.out` 内容干净（仅 `TASK_N_DONE`），现网未触发，但 devin 引用指令原文的 false-pass 路径仍在，催办机制依赖该判定。

## Low

| 级别 | 行号 | 问题 | 建议 |
|---|---|---|---|
| low | 269, 243–245 | `grep -c needs_review` 把 parent 行和 check-retry 行各计一次 → 复核数翻倍 | 按 step 去重或仅汇总行记 verdict |
| low | 234, 242, 250 | retry 路径 parent 行 `"end"=T1`（首轮结束）而 `secs` 含催办 → `end-start≠secs`，end 失真 | retry 后 `T1=$T1b` 再写 stats |
| low | 251 | needs_review（RC=0）仍写 done.steps → resume 跳过待复核步 | 语义需人工确认；可把 verdict 记入 done.steps |
| low | 166–172 | `sid_latest` 的 `devin list` 继承循环 heredoc stdin（与刚修的 devin stdin 同类） | 顺手 `</dev/null`，零成本 |
| low | 156–160 | `DEVIN_ARGS` 仍无引用展开，含空格/glob 值拆碎参数 | 数组化 `"${DEVIN_ARGS[@]}"` |
| low | 264 | `session.id` 仅正常收尾时写；中断 run 缺失（session.ids 增量写仍可 resume，仅影响人工 `-r`） | 每步捕获 SID 时同步写 session.id |
| low | 271 | "最后一份即全量"在 --fresh 下不成立（每组独立会话） | 注释按模式区分 |
| low | 149, 196 | `x` 的 `wait` 无超时可能挂死；INT 路径 kill 不 wait 可能留孤儿（模块 1 M4 未修） | TERM→有界等待→KILL |
| low | 146–152 | SIGTSTP 仍无处理，Ctrl-Z 挂起期间 tty 留 raw（模块 1 M3 未修） | TSTP/CONT trap |

## README vs 当前脚本不一致

| 级别 | README 行 | 问题 | 建议 |
|---|---|---|---|
| med | 179 | "续跑用 `devin -c -p`"已过时：实际走 session.ids + `-r $SID` | 改写为 -r/session.ids 机制 |
| med | 218 | 排查表仍写"-c 接了错误的最近会话"；对应新故障是"SID 抓取钉错会话"（M3-1） | 更新排查文案 |
| low | 225 | "会话定位靠'最近'：-c/session.id"——仅 sid_latest 抓取瞬间依赖 recency，链式续接已确定 | 改为"首步抓 SID 瞬间竞态"caveat |
| low | 148–155 | 日志清单未列 `session.ids`、`_inline-*-retry.txt`、`export-*-retry.json` | 补全文件清单 |
| low | 53 | "缺失时只跑 start"——实际 start+check 都跑且 check prompt 引用"end 的要求" | 更正描述 |
| low | 149 | stats 示例未覆盖 `kind:"check-retry"` 行 | 补示例行 |
| low | 180 | "session.id 不变"仅非 fresh 成立；--fresh 续跑各组不同 | 注明前提 |
| low | 84 | QUEUE_MODEL 说明写"-c 续会话时"，应含 -r | 措辞更新 |
| low | 35 | `-h` 输出 `2,17p` 仍漏 L18–20 会话链注释行 | 改 `2,20p` |

## 已验证非问题

- **RESUME_DONE 读取时机**：L84–90 先于 L130 `mkdir`，不受新 LOGDIR 干扰。
- **done.steps 匹配**：`grep -qx` 整行精确匹配，key 仅数字+固定后缀，无注入面。
- **stats 字段转义**：step/kind 全为脚本生成值，引号/反斜杠无来源。
- **retry RC 覆盖**（模块 1 L3）已修：RC2 独立 `check-retry` stats 行，parent RC 不再被覆盖。
- **write_prompt**：`_inline-{key,key-retry}.txt` 唯一命名，路径与内容经 `--prompt-file` 引用安全。
- **.gitignore**：`logs/`+`prompts/` 覆盖全部产物（session.ids/_inline/export/stats/done.steps）；`prompts-example/` 已 git 跟踪，示例有意提交。
- **自查 prompt 与 README L113 逐字一致**；权限菜单 5 档文案一致。
- **stdin `</dev/null` + `9<&-`**（模块 1 H2）已实装，README "实测复现过"声明属实。
- **exec 大括号修复**（模块 1 H1）已实装，stderr 反馈恢复。
- **session.ids 逐步增量写**：中断 run 也可凭它 resume 到会话，鲁棒性优于仅写 session.id。
- **poll 循环/ps 僵尸判定/wait 退出码**：沿用上版，复核仍正确。

## 小结

模块 1 修复落地后，风险重心转移到 **SID 生命周期**：抓取竞态/失败钉死（M3-1，建议改读 export 的 session_id，改动小）、resume 三处碰撞遮蔽（M3-2/3/4）、死会话无熔断（M3-5）。README 主要残留 `-c` 时代的机制描述（L179/218/225），会在用户排查续跑故障时指错方向。
