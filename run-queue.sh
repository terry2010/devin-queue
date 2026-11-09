#!/usr/bin/env bash
# run-queue.sh — 按数字顺序把 prompts 目录里的 N-start.txt / N-end.txt 依次喂给 Devin。
#
# 用法（在项目目录里执行，devin 会话就落在该项目目录）：
#   run-queue.sh <prompts目录> [--yes] [--no-check] [--fresh] [--resume] [--list]
#
# 运行中控制：q=本步完成后退出  x=立即退出  Ctrl-C=中断
#
# 环境变量：
#   QUEUE_MODEL         传给 devin --model
#   QUEUE_PERM          预设 --permission-mode（不设则启动时弹菜单选择）
#   QUEUE_TRUST=false   目录未被信任时跳过 workspace trust 检查（-p 模式遇未信任目录会直接失败）
#   QUEUE_SANDBOX=1     传 --sandbox，exec 命令沙箱化只能写工作区（配合 QUEUE_PERM=dangerous 更稳）
#   QUEUE_CHECK=0       跳过每对任务后的自查轮（等同 --no-check）
#   QUEUE_CHECK_PROMPT  自定义自查 prompt
#
# 记录：logs/<时间戳>/{stats.jsonl, step-*.out, export-*.json, done.steps}
# 注意：devin -c 续的是"当前目录最近会话"，跑批期间别在同目录另开 devin。

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_ROOT="$SCRIPT_DIR/logs"

PROMPTS=""; ASSUME_YES=0; DO_CHECK="${QUEUE_CHECK:-1}"; FRESH=0; RESUME=0; LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=1 ;;
    --no-check) DO_CHECK=0 ;;
    --fresh)    FRESH=1 ;;
    --resume)   RESUME=1 ;;
    --list|-l)  LIST_ONLY=1 ;;
    -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
    -*)         echo "未知参数: $1" >&2; exit 2 ;;
    *)          [ -z "$PROMPTS" ] && PROMPTS="$1" || { echo "多余参数: $1" >&2; exit 2; } ;;
  esac; shift
done

[ -z "$PROMPTS" ] && PROMPTS="$SCRIPT_DIR/prompts"
case "$PROMPTS" in
  /*) ;;
  *)  [ -d "$SCRIPT_DIR/$PROMPTS" ] && PROMPTS="$SCRIPT_DIR/$PROMPTS" || PROMPTS="$(pwd)/$PROMPTS" ;;
esac
[ -d "$PROMPTS" ] || { echo "prompts 目录不存在: $PROMPTS" >&2; exit 2; }
command -v devin >/dev/null 2>&1 || { echo "找不到 devin CLI" >&2; exit 2; }

# ---------- 发现任务 ----------
NUMS=$(for f in "$PROMPTS"/*-start.txt; do
         [ -e "$f" ] || continue
         basename "$f" | sed -n 's/^\([0-9][0-9]*\)-start\.txt$/\1/p'
       done | sort -n | uniq)
[ -n "$NUMS" ] || { echo "在 $PROMPTS 里没找到 N-start.txt" >&2; exit 2; }

STEPS=""
for n in $NUMS; do
  STEPS="$STEPS
$n start"
  if [ -f "$PROMPTS/$n-end.txt" ]; then STEPS="$STEPS
$n end"; else echo "⚠ $n-start.txt 没有配对的 $n-end.txt" >&2; fi
  [ "$DO_CHECK" = 1 ] && STEPS="$STEPS
$n check"
done
for f in "$PROMPTS"/*-end.txt; do
  [ -e "$f" ] || continue
  n=$(basename "$f" | sed -n 's/^\([0-9][0-9]*\)-end\.txt$/\1/p')
  [ -n "$n" ] && [ ! -f "$PROMPTS/$n-start.txt" ] && echo "⚠ $n-end.txt 没有配对的 start" >&2
done
STEPS=$(printf '%s' "$STEPS" | sed '/^$/d')
TOTAL=$(printf '%s\n' "$STEPS" | wc -l | tr -d ' ')
PAIRS=$(printf '%s\n' "$NUMS" | wc -l | tr -d ' ')

echo "== 队列清单 =="
printf '%s\n' "$STEPS" | while read -r n kind; do
  case "$kind" in
    check) echo "    $n  自查（遗漏则补做）" ;;
    *)     echo "    $n  $kind  <-  $n-$kind.txt" ;;
  esac
done
echo "共 $PAIRS 组任务、$TOTAL 步"
[ "$LIST_ONLY" = 1 ] && exit 0

# ---------- --resume：读最近一次 run 的 done.steps（在建新日志目录之前） ----------
RESUME_DONE=""
if [ "$RESUME" = 1 ]; then
  LAST_RUN=$(for d in "$LOG_ROOT"/*/; do [ -f "$d/done.steps" ] && echo "$d"; done | sort | tail -1)
  [ -n "$LAST_RUN" ] && RESUME_DONE=$(cat "$LAST_RUN/done.steps")
  [ -z "$RESUME_DONE" ] && echo "⚠ 没找到可续跑的 done.steps，从头执行" >&2
fi

# ---------- 权限模式 ----------
PERM="${QUEUE_PERM:-}"
SANDBOX="${QUEUE_SANDBOX:-0}"
if [ -z "$PERM" ]; then
  if [ -r /dev/tty ]; then
    cat > /dev/tty <<'EOF'
权限模式：
  1) auto             只自动批准只读工具（改文件会停下来等审批）
  2) accept-edits     + 自动批准工作区文件编辑
  3) smart            + 快模型判定安全的动作自动执行（推荐）
  4) dangerous        全部工具自动批准（bypass，无人值守）
  5) dangerous+沙箱   同 4，但 exec 只能写工作区（无人值守推荐）
EOF
    printf '选择 [1-5，默认3]: ' > /dev/tty
    read -r pc < /dev/tty || pc=""
    case "$pc" in
      1|auto)         PERM="auto" ;;
      2|accept-edits) PERM="accept-edits" ;;
      4|dangerous)    PERM="dangerous" ;;
      5)              PERM="dangerous"; SANDBOX=1 ;;
      ""|3|smart)     PERM="smart" ;;
      *) echo "无效选择，使用 smart" > /dev/tty; PERM="smart" ;;
    esac
  else
    echo "⚠ 非交互环境且未设 QUEUE_PERM，devin 用默认 auto 档（可能卡在审批）" >&2
  fi
fi
[ -n "$PERM" ] && echo "权限模式: $PERM$([ "$SANDBOX" = 1 ] && echo ' + sandbox')"

# ---------- 确认 ----------
if [ "$ASSUME_YES" != 1 ]; then
  printf '开始执行？[y/N] ' > /dev/tty
  read -r ans < /dev/tty || exit 1
  case "$ans" in y|Y|yes) ;; *) echo "已取消"; exit 0 ;; esac
fi

# ---------- 日志 ----------
TS=$(date +%Y%m%d-%H%M%S); LOGDIR="$LOG_ROOT/$TS"; mkdir -p "$LOGDIR"
STATS="$LOGDIR/stats.jsonl"; DONEFILE="$LOGDIR/done.steps"
: > "$STATS"; : > "$DONEFILE"
echo "日志: $LOGDIR"

# ---------- 终端控制 ----------
TTY_OK=0; STTY_SAVED=""
if exec 9</dev/tty 2>/dev/null; then
  TTY_OK=1
  STTY_SAVED=$(stty -g </dev/tty 2>/dev/null || true)
  stty -icanon -echo </dev/tty 2>/dev/null || true
fi
STOP_AFTER=0; CUR_PID=""
cleanup() {
  [ -n "$STTY_SAVED" ] && stty "$STTY_SAVED" </dev/tty 2>/dev/null
  [ -n "$CUR_PID" ] && kill "$CUR_PID" 2>/dev/null
}
trap 'cleanup; echo; echo "✗ 已中断（当前步未完成），续跑: --resume"; exit 130' INT
trap 'cleanup' EXIT
poll_key() { local k=""; [ "$TTY_OK" = 1 ] && IFS= read -t 0.2 -r -n 1 k <&9 2>/dev/null; printf '%s' "$k"; }

# ---------- devin 调用 ----------
DEVIN_ARGS=""
[ -n "${QUEUE_MODEL:-}" ] && DEVIN_ARGS="$DEVIN_ARGS --model $QUEUE_MODEL"
[ -n "$PERM" ] && DEVIN_ARGS="$DEVIN_ARGS --permission-mode $PERM"
[ "${QUEUE_TRUST:-true}" = "false" ] && DEVIN_ARGS="$DEVIN_ARGS --respect-workspace-trust false"
[ "$SANDBOX" = "1" ] && DEVIN_ARGS="$DEVIN_ARGS --sandbox"
FIRST_STEP=1
[ "$RESUME" = 1 ] && [ -n "$RESUME_DONE" ] && FIRST_STEP=0   # 续跑接同一会话

run_devin() {  # $1=key $2=prompt文件 $3=out文件
  local label="$1" src="$2" out="$3" args rc t0 k
  if [ "$FIRST_STEP" = 1 ]; then args="-p"; else args="-c -p"; fi
  devin $args $DEVIN_ARGS --export "$LOGDIR/export-$label.json" --prompt-file "$src" > "$out" 2>&1 &
  CUR_PID=$!; t0=$SECONDS
  while :; do
    local st; st=$(ps -p "$CUR_PID" -o stat= 2>/dev/null)
    [ -z "$st" ] && break          # 进程已回收
    case "$st" in *Z*) break ;; esac  # 僵尸：kill -0 仍会成功，必须单独判
    sleep 1; printf '\r    ⏱ %ds' "$((SECONDS-t0))" >&2
    k=$(poll_key)
    case "$k" in
      q) STOP_AFTER=1; echo >&2; echo "⏸  收到 q：本步完成后退出" >&2 ;;
      x) echo >&2; echo "✗ 收到 x：立即退出" >&2
         kill "$CUR_PID" 2>/dev/null; wait "$CUR_PID" 2>/dev/null; CUR_PID=""; cleanup; exit 130 ;;
    esac
  done
  printf '\r        \r' >&2
  wait "$CUR_PID"; rc=$?; CUR_PID=""
  FIRST_STEP=0
  return $rc
}

write_prompt() { printf '%s' "$2" > "$LOGDIR/_inline-$1.txt"; printf '%s' "$LOGDIR/_inline-$1.txt"; }

# ---------- 主循环（重定向而非管道，避免子 shell 丢状态） ----------
IDX=0
echo "控制键: q=本步后退出  x=立即退出  Ctrl-C=中断"
while read -r n kind; do
  IDX=$((IDX+1)); key="$n-$kind"
  if [ -n "$RESUME_DONE" ] && printf '%s\n' "$RESUME_DONE" | grep -qx "$key"; then
    echo "[$IDX/$TOTAL] ↷ $key 已完成，跳过"; continue
  fi

  case "$kind" in
    check)
      P="${QUEUE_CHECK_PROMPT:-任务 $n 自查：对照本任务 start/end 的要求，检查是否还有未完成或遗漏的部分。若有遗漏，请立即补做完成；全部完成后只回复一行 TASK_N_DONE}"
      SRC=$(write_prompt "$key" "$P") ;;
    *) SRC="$PROMPTS/$n-$kind.txt" ;;
  esac
  [ "$FRESH" = 1 ] && [ "$kind" = start ] && FIRST_STEP=1   # 每组新开会话

  echo "[$IDX/$TOTAL] ▸ $key  执行中…"
  OUT="$LOGDIR/step-$key.out"
  T0=$(date +%s)
  run_devin "$key" "$SRC" "$OUT"; RC=$?
  T1=$(date +%s); SECS=$((T1-T0)); VERDICT="-"

  if [ "$kind" = check ] && [ "$RC" = 0 ]; then
    if grep -q "TASK_N_DONE" "$OUT"; then VERDICT="pass"
    else
      echo "    ↻ $n 自查未确认，催办一次"
      SRC2=$(write_prompt "$key-retry" "任务 $n 自查尚未收尾：请继续把遗漏补完，完成后只回复一行 TASK_N_DONE")
      T0b=$(date +%s); run_devin "$key-retry" "$SRC2" "$OUT.retry"; RC=$?; T1=$(date +%s)
      SECS=$((SECS+T1-T0b))
      if grep -q "TASK_N_DONE" "$OUT.retry" 2>/dev/null; then VERDICT="pass"; else VERDICT="needs_review"; fi
    fi
  fi

  printf '{"step":"%s","kind":"%s","start":%d,"end":%d,"secs":%d,"exit":%d,"verdict":"%s"}\n' \
    "$key" "$kind" "$T0" "$T1" "$SECS" "$RC" "$VERDICT" >> "$STATS"
  [ "$RC" = 0 ] && echo "$key" >> "$DONEFILE"

  mark="✓"; [ "$RC" != 0 ] && mark="✗"; [ "$VERDICT" = needs_review ] && mark="!"
  echo "[$IDX/$TOTAL] $mark $key  ${SECS}s  (exit=$RC)"
  [ "$STOP_AFTER" = 1 ] && { echo "■ 按要求在本步后停止"; break; }
done <<EOF
$STEPS
EOF

# ---------- 汇总 ----------
echo; echo "== 汇总 =="
# devin list 按最近活跃排序，第一条即本次队列会话
SID=$(devin list --format json 2>/dev/null | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$SID" ]; then
  echo "$SID" > "$LOGDIR/session.id"
  echo "会话ID: $SID   （恢复: devin -r $SID）"
fi
awk -F'"secs":|,"exit"' '{s+=$2} END{printf "总耗时 %ds\n", s}' "$STATS"
echo "失败步数: $(awk -F'"exit":|,"verdict"' '$2!=0' "$STATS" | wc -l | tr -d ' ')"
echo "需人工复核: $(grep -c needs_review "$STATS" || true)"
echo "明细: $STATS"
echo "完整会话导出: $LOGDIR/export-*.json（最后一份即全量）"
echo "中断续跑: $0 $PROMPTS --resume"
