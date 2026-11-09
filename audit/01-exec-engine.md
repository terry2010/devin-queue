# 审计 01：执行引擎与会话管理

对象：`run-queue.sh`（L133–178 终端控制/run_devin、L149–155 DEVIN_ARGS/FIRST_STEP、L185–222 主循环交互路径、L228–240 会话汇总）。

验证方式：逐行审查 + 实测 bash 5.3 / 3.2 重定向与信号语义、macOS `ps -o stat=`、`wait` 退出码；只读查阅 devin `--help`、官方文档与二进制内字符串，未启动任何 devin 会话。

## High

| 级别 | 行号 | 问题 | 建议 |
|---|---|---|---|
| high | 134 | `exec 9</dev/tty 2>/dev/null` 将脚本 stderr 永久重定向到 /dev/null | `if { exec 9</dev/tty; } 2>/dev/null; then`，把错误抑制限定在 exec 语句本身 |
| high | 160 | devin 继承主循环 stdin（$STEPS heredoc），读一次即吞掉剩余任务行 | `devin ... </dev/null > "$out" 2>&1 &` |

- **L134**：`exec` 无命令时所有重定向永久生效且从左到右处理。`9</dev/tty` 成功后 `2>/dev/null` 立即接管 fd 2——此后 L166 计时器、L169–170 q/x 回显、及全部 bash 错误消息静默丢失（已实测复现）。无 tty 时顺序相反：`9<` 先失败，`2>/dev/null` 不执行，本想抑制的打开错误照样打印。两个分支都没达到目的。
- **L160**：`run_devin` 在 `while read` 循环体内运行，devin 未重定向 stdin，fd 0 与 heredoc 共享文件偏移。devin 二进制含 `stdin is piped`、`failed to read stdin:`、`/dev/stdin` 检测字符串，很可能读取管道 stdin（**需人工确认**）；即便当前不读，devin spawn 的任何子进程读一次，主循环 `read` 即丢行，后续步骤静默跳过。

## Med

| 级别 | 行号 | 问题 | 建议 |
|---|---|---|---|
| med | 155,159,176,187 | `-c` 续接"当前目录最近未锁定会话"，多场景静默接错会话 | 首步成功后取 session id 改用 `devin -r "$SID"`；`-c` 失败时中止队列 |
| med | 206,212 | `grep -q "TASK_N_DONE"` 未锚定，输出引用该串即假阳性 pass | `grep -qx 'TASK_N_DONE'` 整行匹配，或只查最后一行 |
| med | 133–145 | SIGTSTP(Ctrl-Z) 无处理，挂起期间 tty 停在 -icanon -echo，外层 shell 错乱 | 增加 TSTP/CONT trap：TSTP 时恢复 stty 后自停，CONT 时重设 |
| med | 142,171 | kill 路径不对称：`x` 的 `wait` 无超时可能挂死；INT 路径 kill 不 wait 可能留孤儿 | TERM → 有界等待 → `kill -9`；INT 路径 kill 后 `wait` |

- **`-c` 会话链**：`devin -c` 选"最近且未被其他进程锁定的会话"。具体破口：(a) L176 `FIRST_STEP=0` 无条件执行——首步若在建会话前失败（未信任目录/auth），后续 `-c` 接到无关旧会话；(b) --resume 时旧 devin 仍存活 → 会话被锁 → `-c` 跳到更老会话；(c) --fresh+--resume：任务 2 的 check 待跑，但任务 3 已建更新会话 → `2-check` 落进任务 3 的会话；(d) 目录无会话 → `No sessions to continue` 每步重复失败，无熔断。L18 注释只提了"别另开 devin"，未覆盖这些。
- **`TASK_N_DONE` 判定**：`$OUT` 是 devin 全部输出，引用指令原文（如"未能输出 TASK_N_DONE 因为…"）即命中，retry 催办被跳过、needs_review 永不触发，自查机制形同虚设。
- **SIGTSTP**：脚本+devin 同前台进程组，Ctrl-Z 整组停止而 tty 保持 raw 模式。注：SIGTERM/SIGQUIT 实测在 bash 3.2/5.3 上**会**执行 EXIT trap，stty 能恢复，不算 bug，仅缺 resume 提示。
- **kill 路径**：devin 若装 TERM handler 做慢速收尾，`x` 的 `wait` 无限阻塞，违背"立即退出"；INT 路径 cleanup 只 `kill` 不 `wait`，TERM 被处理时 devin 变孤儿继续写工作区，且 CUR_PID 未清空导致 EXIT trap 重复 kill。

## Low

| 级别 | 行号 | 问题 | 建议 |
|---|---|---|---|
| low | 149–153,160 | `$DEVIN_ARGS` 未引用，值含空格/glob 会拆碎参数表 | 数组拼装 `DEVIN_ARGS+=()` + `"${DEVIN_ARGS[@]}"` |
| low | 218 | needs_review 步（RC=0）仍写 done.steps，resume 跳过复核 | 按需确认；如需保留复核应改为记录 verdict |
| low | 210 | retry 覆盖 RC，stats 丢失首次 check 失败记录 | 分别记录两次 RC 或额外记 attempt 字段 |
| low | 230 | `sed` 取 JSON 首个 `"id"` 可能命中嵌套字段；--fresh 仅记录最后一个会话 | 用 `jq` 或解析 export json 的 session 字段 |
| low | 93–124 vs 146 | canonical 模式菜单期间的 type-ahead 残留在 tty 缓冲，poll_key 可能误食 `x`/`q` | 进 raw 模式前 `read -t 0.1` 冲刷输入缓冲（需人工确认触发性） |
| low | 120–124 | 确认提示缺 `[ -r /dev/tty ]` 守卫（菜单有），headless 时死于重定向错误 | 与 L94 保持一致的守卫或报错文案 |
| low | 152 | `QUEUE_TRUST` 仅认精确 `false`，`0`/`no` 静默按 true | 按文档取值或补充合法值映射 |
| low | 160–161 | `devin &` 与 `CUR_PID=$!` 之间的 INT 使 devin 孤儿化 | 窗口极小；可在 CUR_PID 赋值前先设置 trap 或合并语义 |
| low | 142,171 | `x` 退出码 130 与 SIGINT 不可区分；INT 路径 cleanup 经 EXIT trap 双跑 | 用独立退出码；cleanup 内清空 CUR_PID 保证幂等 |
| low | 134 | fd 9(/dev/tty) 被 devin 及其子进程继承，理论上可被读取偷走控制键 | 启动 devin 时 `9<&-` 关闭继承 |
| low | 239 | 注释"最后一份即全量"在 --fresh 下不成立（每组独立会话） | 注释按模式区分说明 |

- **DEVIN_ARGS**：`QUEUE_MODEL="foo bar"` → `bar` 成游离位置参数被 `[PATH]`/`[PROMPT]` 接住；含 `*` → 展开为 cwd 文件名。非安全边界但为真 quoting bug；数组化还消除 `-p`/`--export` 可选值 flag 依赖"下一个 token 以 `-` 开头"的隐性脆弱。
- **L218**：语义问题——"完成但未确认"是否算 done 影响 resume 行为，**需人工确认**设计意图。
- **L8/L9/L10**：窗口、语义与卫生类小问题，集中列出不展开。

## 已验证非问题

- **ps/zombie 检测（L163–165）**：macOS `ps -o stat=` 对 zombie 返回 `Z`，`*Z*` 匹配正确；bash 在命令边界自动收割 async 子进程，`[ -z "$st" ]` 覆盖已回收情形。`wait "$CUR_PID"` 对已回收 pid 返回真实退出码（实测 rc=0），信号死为 128+n。
- **heredoc 循环无子 shell**（L182 注释属实）：FIRST_STEP/STOP_AFTER 在主 shell 内持久生效。
- **FIRST_STEP/--fresh/--resume 机制本身**：skip 判定（L187）先于 reset（L197），跳过的 start 不误触发新会话；resume 空 done.steps 保持 `-p` 新会话。机制正确，问题仅在于 `-c` 不可确定性（见 med）。
- **SIGINT 双投递**：bash 为后台子进程置 SIGINT→SIG_IGN（实测 INT 免疫），Ctrl-C 只中脚本；除非 devin 自装 handler（很可能，需人工确认），并发路径仍收敛。
- **`grep -qx "$key"`**（L187）：key 仅数字+连字符，无正则特殊符。
- **可选值 flag 解析**：`-p`/`--export`/`-r` 当前参数序后随 token 均以 `-` 开头，不会误吞值。
