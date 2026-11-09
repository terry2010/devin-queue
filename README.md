# devin-queue

把一个目录里的 `N-start.txt` / `N-end.txt` 按数字顺序、在**同一个 Devin 会话**里依次执行。

适用场景：分模块审计、分阶段实现、任何"人工要连续敲十几条 prompt"的批量任务。脚本替你按顺序喂 prompt、跑自查、记录全程、统计耗时，还能随时中断续跑。

## 执行模型

```
1-start.txt → 1-end.txt → 1-自查 → 2-start.txt → 2-end.txt → 2-自查 → …
   devin -p    devin -c -p  devin -c -p   devin -c -p   devin -c -p   devin -c -p
   └────────────────── 同一个会话（上下文累积）──────────────────┘
```

- 第一步 `devin -p` 在当前目录开新会话
- 之后每步 `devin -c -p` 续"本目录最近会话"——第 12 组也能看到第 1 组干的活
- 自查轮让模型自己检查遗漏并补做（见下文）

## 环境要求

- macOS / Linux，bash 3.2+（系统自带 bash 即可）
- `devin` CLI 已安装并登录（`devin doctor` 可验证）
- 运行目录需要先被 devin 信任过，否则设 `QUEUE_TRUST=false`（见参数表）

## 快速开始

```bash
# 1. 把任务 prompt 放进一个目录，按数字命名
prompts/
  1-start.txt   1-end.txt
  3-start.txt   3-end.txt      # 数字可以不连续，按数值排序
  12-start.txt  12-end.txt

# 2. 在【要干活的项目目录】里执行（devin 会话落在这里）
cd /你的项目
/Volumes/2t/code/devin-queue/run-queue.sh /Volumes/2t/code/devin-queue/prompts

# 3. 确认清单后开始
== 队列清单 ==
    1  start  <-  1-start.txt
    1  end  <-  1-end.txt
    1  自查（遗漏则补做）
    ...
共 3 组任务、9 步
开始执行？[y/N] y
```

## 文件命名约定

| 规则 | 说明 |
|---|---|
| `N-start.txt` | 必需，每组任务的第一个 prompt |
| `N-end.txt` | 可选，本组收尾 prompt；缺失时只跑 start 并打印警告 |
| 数字 N | 按数值排序（1, 3, 12 而不是 1, 12, 3），不要求连续 |
| 孤儿文件 | 有 `N-end.txt` 没 `N-start.txt` → 警告并跳过 |
| 其他文件 | `N-*.txt` 以外的文件会被忽略 |

prompt 文件内容原样作为完整 prompt 发给 devin（通过 `--prompt-file`，多行、特殊字符都安全）。

## 参数

```bash
run-queue.sh <prompts目录> [选项]
```

| 参数 | 说明 |
|---|---|
| `<prompts目录>` | 相对路径先按脚本目录解析，再按当前目录；省略时用 `<脚本目录>/prompts` |
| `--yes` `-y` | 跳过"开始执行？"确认，直接跑 |
| `--no-check` | 跳过每组后的自查轮（start→end→直接下一组） |
| `--fresh` | 每组任务开新会话（组内 start/end/自查仍同一会话）。默认全程同一会话 |
| `--resume` | 断点续跑：读最近一次 run 的 `done.steps`，已完成步骤自动跳过 |
| `--list` `-l` | 只打印队列清单，不执行 |
| `-h` `--help` | 帮助 |

## 环境变量

```bash
QUEUE_MODEL=opus QUEUE_PERM=accept-edits QUEUE_TRUST=false run-queue.sh prompts
```

| 变量 | 说明 |
|---|---|
| `QUEUE_MODEL` | 传给 `devin --model`。注意：`-c` 续会话时 model 语义是"给该会话切模型"，不传则沿用会话原有模型 |
| `QUEUE_PERM` | 传给 `--permission-mode`。**不设时启动会弹菜单选**，预设则跳过菜单 |
| `QUEUE_TRUST=false` | 传 `--respect-workspace-trust false`。-p 非交互模式遇到未信任目录**不会弹确认而是直接失败**，新项目目录必设 |
| `QUEUE_SANDBOX=1` | 传 `--sandbox`，exec 进程沙箱化（只能写工作区）。配合 `dangerous` 是"放手但不裸奔"的推荐组合 |
| `QUEUE_CHECK=0` | 同 `--no-check` |
| `QUEUE_CHECK_PROMPT` | 自定义自查 prompt（见下节） |

## 权限模式

不设 `QUEUE_PERM` 时，启动在确认前会弹菜单：

```
权限模式：
  1) auto             只自动批准只读工具（改文件会停下来等审批）
  2) accept-edits     + 自动批准工作区文件编辑
  3) smart            + 快模型判定安全的动作自动执行（推荐）
  4) dangerous        全部工具自动批准（bypass，无人值守）
  5) dangerous+沙箱   同 4，但 exec 只能写工作区（无人值守推荐）
选择 [1-5，默认3]:
```

四档含义：`auto`（默认，只读）→ `accept-edits`（+文件编辑）→ `smart`（+快模型判定安全）→ `dangerous`（全部批准 = bypass）。**无人值守跑批务必选 4 或 5**，或预设 `QUEUE_PERM=dangerous` 跳过菜单——否则 exec 审批会卡住队列。选 5 是"放手但不裸奔"：exec 被沙箱限制只能写工作区。

非交互环境（cron/nohup）不设 `QUEUE_PERM` 不会弹菜单，回落到 devin 默认 auto 并打警告。

## 自查轮机制

每组 `end` 完成后自动发一条内置 prompt：

> 任务 N 自查：对照本任务 start/end 的要求，检查是否还有未完成或遗漏的部分。若有遗漏，请立即补做完成；全部完成后只回复一行 TASK_N_DONE

判定逻辑（不猜自然语言，认标记）：

```
自查输出含 TASK_N_DONE → verdict=pass，进入下一组
否则 → 自动催办一次（"继续收尾并回复 TASK_N_DONE"）
       仍无标记 → verdict=needs_review，记日志后继续推进（不阻塞队列）
```

- 自查和任务在同一会话，模型能直接看到自己刚干的活，有遗漏就在这一轮里补掉
- `needs_review` 的步骤在 `stats.jsonl` 里可查：`grep needs_review logs/*/stats.jsonl`
- 自定义自查词：`QUEUE_CHECK_PROMPT="..."`（务必保留 `TASK_N_DONE` 输出指令）

## 运行中控制

```
控制键: q=本步后退出  x=立即退出  Ctrl-C=中断
[3/9] ▸ 1-end  执行中…    ⏱ 42s     ← 实时秒数
[3/9] ✓ 1-end  47s  (exit=0)        ← 完成后报耗时/退出码
```

| 按键 | 行为 |
|---|---|
| `q` | 当前步**跑完后**退出（devin 进程不被杀，本步成果保留并计入 done.steps） |
| `x` | 立即杀掉当前 devin 进程退出（本步标记未完成） |
| `Ctrl-C` | 同 `x`，打印续跑提示 |

无 TTY 的环境（cron、nohup）控制键自动失效，不影响运行。

## 日志与产物

每次运行在 `logs/<时间戳>/` 下：

```
logs/20261109-220022/
  stats.jsonl        每步一行：{"step":"1-end","kind":"end","start":…,"end":…,"secs":47,"exit":0,"verdict":"-"}
  step-1-start.out   每步的完整 stdout
  step-1-check.out.retry   催办轮输出（如有）
  _inline-1-check.txt      实际发送的自查 prompt 存档
  export-*.json      devin --export 导出的会话（最后一份即全量会话内容）
  done.steps         已完成步骤清单（--resume 依据）
  session.id         队列会话 ID
```

- **逐条计时**：`stats.jsonl` 的 `secs` 是 wall-clock 秒数；要 token 级速度需另配 devin OTel（`api_request.duration_ms`），脚本不管
- **完整会话**：`export-*.json` 是 devin 官方的会话导出（含工具调用），比 stdout 全

## 事后回到会话

```bash
# 方法1：用记录的 ID 精确恢复
devin -r $(cat /Volumes/2t/code/devin-queue/logs/20261109-220022/session.id)

# 方法2：项目目录里交互式挑（队列会话的 title 是第一条 prompt 摘要）
cd /你的项目 && devin -r        # 不带参数出列表
devin list                      # 或先看列表再选
```

## 断点续跑

```bash
run-queue.sh prompts --resume
```

- 读最近一次 run（`logs/` 下最新的含 `done.steps` 的目录）的完成清单，已完成的 `N-start/N-end/N-check` 跳过
- 续跑用 `devin -c -p` 接同一会话——前提是该会话仍是本目录最近的（期间别在同目录跑别的 devin）
- 注意：续跑会新建本次的日志目录，`session.id` 不变（还是同一会话）

## 典型用法

**无人值守跑批**（最常见）：

```bash
cd /你的项目
QUEUE_PERM=accept-edits QUEUE_TRUST=false \
  /Volumes/2t/code/devin-queue/run-queue.sh prompts --yes
```

**分模块审计**（每组一个模块，自查把关质量）：

```
prompts/
  1-start.txt   "审计模块A：鉴权与权限校验，列出所有问题"
  1-end.txt     "把模块A审计结果写入 audit/module-A.md"
  2-start.txt   "审计模块B：输入校验与注入面，列出所有问题"
  2-end.txt     "把模块B审计结果写入 audit/module-B.md"
  …
```

自查轮在同一会话里对照该组要求查漏，遗漏当场补做——正好覆盖"一次一个模块比一把梭深"的需求。

**每组独立上下文**（任务间互不影响）：

```bash
run-queue.sh prompts --fresh   # 每组新会话，组内仍共享
```

## 故障排查

| 现象 | 原因/解决 |
|---|---|
| 第一步就失败、报 trust 相关 | 目录未信任：`QUEUE_TRUST=false` 重跑，或先 `devin` 进交互模式信任一次 |
| 卡住不动、无输出 | 多半是权限审批在等非交互给不了的确认：加 `QUEUE_PERM=accept-edits` |
| `--resume` 没跳过已完成步骤 | 找不到 `done.steps`（换过日志目录/手动删过）→ 从头跑 |
| 续上的会话内容不对 | `-c` 接了错误的最近会话（跑批期间同目录开过别的 devin）→ 改用 `devin -r <session.id>` 手动确认 |
| `needs_review` 一堆 | 自查 prompt 与你的任务不匹配 → 用 `QUEUE_CHECK_PROMPT` 调整判定词 |
| 控制键没反应 | 无 TTY 环境（管道/cron），控制键不可用属正常 |

## 已知限制

- **自查是同会话 self-review**：模型容易"觉得自己没问题"。要严格把关需换异构评审（另一会话/另一模型），那是 acp 脚本或插件层的活
- **会话定位靠"最近"**：`-c`/session.id 都基于"本目录最近会话"，跑批期间同目录开 devin 会错位
- **速度统计只有 wall-clock**：tokens/s 要配 devin OTel collector
- **失败步不阻塞**：某步非零退出只记录继续跑（模型任务失败多是"没干完"而非崩溃），要严格的 fail-fast 可在 `run_devin` 返回后加退出逻辑

## 文件

```
devin-queue/
  run-queue.sh        主脚本
  README.md           本文档
  prompts-example/    示例任务（1/2 两组，可直接 --list 看效果）
  prompts/            你的任务放这里（默认目录）
  logs/               运行产物
```
