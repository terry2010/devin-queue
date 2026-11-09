# 审计 02：任务发现与队列流程

对象：`run-queue.sh` L20–130（参数解析、prompts 目录解析、N-start.txt 发现与排序、孤儿文件检测、STEPS 拼装/读出、队列清单与确认流程）。

验证方式：逐行审查 + 实测 `sort -n | uniq` 文本去重、`case -*` 对 `--` 的匹配、`&&`/`||` 链短路语义、`read` 切分行为。

## Med

| 级别 | 行号 | 问题 | 建议 |
|---|---|---|---|
| med | 84–87 | resume 的 done.steps 不绑定 prompts 目录，跨目录续跑按 key 误匹配 → 静默跳过任务 | LOGDIR 写入队列身份（`$LOGDIR/prompts.path`），resume 只接受路径一致的 run，否则从头执行 |

- `LAST_RUN` 在 LOG_ROOT 全局取最新含 done.steps 的 run，不校验其 prompts 目录；done.steps 只记裸 key `N-kind`。`run-queue.sh promptsB --resume` 时若上次跑的是 promptsA（任务号天然重叠），`grep -qx` 会把 B 队列同号步骤判为已完成 `continue`——**任务静默丢失且无异常输出**。同目录但 prompt 内容被改过时同样按 key 跳过（后者可视为 resume 语义，前者是明确缺陷）。

## Low

| 级别 | 行号 | 问题 | 建议 |
|---|---|---|---|
| low | 34 | `-*` 把 `--` 当未知参数，不支持 end-of-options 惯例 | `case` 加 `--) shift; break ;;` |
| low | 42 | SCRIPT_DIR 优先于 cwd 且静默，两边同名目录都存在时不可见用了哪个；全程不 echo 解析后的 PROMPTS | 确认前 `echo "prompts: $PROMPTS"` |
| low | 51 | `sort -n \| uniq` 文本去重：`01-start.txt` 与 `1-start.txt` 并存 → `01`/`1` 都保留，同号任务跑两遍（key `01-*`≠`1-*`，已实测） | 归一化前导零（`sed 's/^0\+//'`）后再排重 |
| low | 45 | `--list` 仍要求 devin 在 PATH（检查先于 L80 出口），纯展示不应依赖二进制 | devin 检查移到 LIST_ONLY 出口之后 |
| low | 127–129 | `mkdir -p` 不查错；同秒两实例共用 LOGDIR，`: >` 截断对方 stats/done.steps；无实例锁，resume 可选中在飞 run 的 done.steps | `mkdir -p \|\| exit`；LOGDIR 名追加 `$$` 或对 LOG_ROOT flock |
| low | 22 | 经 symlink 调用时 `dirname "$0"` 解析到链接所在目录，LOG_ROOT/默认 prompts 漂移 | `cd -P` + `pwd -P`，或 readlink 解析 |
| low | 33 | `sed -n '2,17p'` 恰漏掉 L18 的 `-c` 会话警告，help 不全 | 改 `2,18p` |
| low | 35–39 | 空串位置参数 `""` 被当作未提供并静默落默认目录 | 参数已提供但为空应 `exit 2` |
| low | 49,58,64 | 存在性谓词不对称：start 为坏 symlink → `-e` 假 → 任务无声消失；end 为目录/坏链 → 报"没有配对 end"且漏孤儿 | 用 `-e \|\| -L` 测存在，再对"非普通文件"单独警告 |
| low | 25,60 | `QUEUE_CHECK` 仅认字面 `1`，`yes`/`true`/`on` 全被当禁用，与 QUEUE_TRUST 的 `=false` 语义不对称 | 统一 truthy 解析或白名单校验+警告 |
| low | 193 | end 缺失时 check prompt 仍写"对照 start/end 的要求"，描述与事实不符 | 按 end 是否存在动态措辞 |

- **L42**：相对路径解析顺序本身符合"先 SCRIPT_DIR 再 cwd"的设计，问题是遮蔽无声——用户确认时看不到实际喂入的目录。
- **L51**：实测 `printf '1\n01\n' | sort -n | uniq` 输出 `01` 与 `1` 两行——uniq 按文本去重，不同写法产生不同 key 与独立步骤。
- **L49/58/64**：`-e` 跟随 symlink，坏链即不存在；`-f` 还要求普通文件。三处口径不一导致"名存实亡"的文件既不配对也无告警。
- **其余 low** 为卫生/约定类问题，表中已含修法，不展开。

## 已验证非问题

- **数字提取正则**：`^\([0-9][0-9]*\)-start\.txt$` 全锚定——`12abc-start.txt`、`x1-start.txt`、`1-start2.txt` 整体不匹配直接跳过，无半截提取。
- **glob 无匹配**：`[ -e "$f" ] || continue` 正确处理未展开字面量，无需 nullglob。
- **`for n in $NUMS` 无引号切分**：内容仅数字，按换行切分安全。
- **STEPS 拼装/读出**：首空行由 L68 `sed '/^$/d'` 清除；`while read -r n kind` IFS 切分 + `-r` 防反斜杠；heredoc 自带尾换行，末行不丢；NUMS 非空 ⇒ STEPS ≥2 行不为空。
- **`sort -n` 排序**：数值序正确（`2` 先于 `10`）。
- **孤儿检测双向对称**（L58/L64–66），`[ -n "$n" ]` 守卫畸形文件名。
- **参数解析主干**：未知参数、多余位置参数均 `exit 2`；`-h` 正常退出；`&&`/`||` 链中赋值恒真，无短路陷阱。
- **确认流程**：`/dev/tty` EOF → `exit 1`；非 `y|Y|yes` → `exit 0`；菜单选项映射含默认档正确。
- **`--list`**：在 tty 设置/trap 安装前 `exit 0`，无副作用泄漏。
- **`wc -l` 计数**：`printf '%s\n'` 补尾换行，不依赖源数据结尾。

## 小结

主干链（发现→排序→拼装→读出）健壮；实质问题集中在 resume 队列身份缺失（1 med）与边界/校验细节（11 low）。
