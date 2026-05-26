#!/usr/bin/env bash
# shellcheck shell=bash
# scaffolding-health.sh — watcher の scaffolding health gate / doctor モジュール
#
# 用途:
#   worktree 内の `.claude/agents` / `.claude/rules` 足場の到達性を「実際に届いて
#   いるか」のレベルで能動検証・可視化する scaffolding health gate (#238) と、各
#   crontab repo の装備状態を副作用なく点検する doctor サブコマンドの関数定義を
#   集約する。#237 は `.claude/` を worktree へ届ける delivery 側の対策であり、本
#   モジュールは delivery が届いたかを検証する側を担い、ルール非装備の degraded
#   実行が silent に agent stage へ進む事故を構造的に防ぐ。
#   - sh_log / sh_warn / sh_error              : `scaffolding-health:` 3 段 prefix logger
#   - sh_inspect_scaffolding                   : 指定 worktree の agents/rules 非空到達性検査
#                                                （純関数 / read-only / 0=full / 1=missing / 2=indeterminate）
#   注: preflight gate（sh_preflight_gate）/ 可視シグナル（_sh_emit_visibility_signal）/
#   doctor（sh_doctor_*）は後続タスク（#238 task 2 / 3）で本モジュールに追加される。
#
# 配置先:
#   $HOME/bin/modules/scaffolding-health.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO 等）は本体冒頭の Config ブロックで定義済み。bash の遅延束縛により
#     呼び出し時に解決される（sh_inspect_scaffolding 自体は $REPO に依存しない純関数）。
#   - 外部 CLI: date / find / test 演算子（`[ -d ]` 等）。
#
# セットアップ参照先:
#   - 要件: docs/specs/238-feat-watcher-scaffolding-health-gate-wor/requirements.md
#   - 設計: docs/specs/238-feat-watcher-scaffolding-health-gate-wor/design.md

# scaffolding-health 専用ロガー（既存 sav_* / qa_* と同形式 / Issue #119 規約）。
# 行頭 `[YYYY-MM-DD HH:MM:SS] [$REPO] scaffolding-health:` の 3 段 prefix を維持し、
# `grep '\[.*\] scaffolding-health:'` で全件抽出可能（Req 1.2, 1.4, 3.2, NFR 2.1）。
# sh_log は stdout、sh_warn / sh_error は >&2。$REPO は本体側グローバルの遅延束縛。
sh_log() {
  echo "[$(date '+%F %T')] [$REPO] scaffolding-health: $*"
}
sh_warn() {
  echo "[$(date '+%F %T')] [$REPO] scaffolding-health: WARN: $*" >&2
}
sh_error() {
  echo "[$(date '+%F %T')] [$REPO] scaffolding-health: ERROR: $*" >&2
}

# ─── sh_inspect_scaffolding ───
# 指定 worktree 配下の `.claude/agents` / `.claude/rules` の非空到達性を判定する純検査関数。
#
# 入力:
#   $1 = 検査対象の worktree 絶対パス（その配下の .claude/agents, .claude/rules を見る）
# stdout:
#   missing 時のみ機械可読サマリ `agents=<ok|missing> rules=<ok|missing>` を 1 行出力。
#   full 時・indeterminate 時は stdout に何も出さない。
# 戻り値:
#   0 = full          : 両ディレクトリに非空の通常ファイルが 1 つ以上ある
#   1 = missing       : いずれかのディレクトリが不在 or 空
#   2 = indeterminate : 真の I/O 異常で存否を確定できない（fail-open。呼び出し側で warn 継続）
#
# 制約:
#   - 副作用なし（read-only）。worktree / FS へ書き込まない。
#   - 同一 worktree 状態に対して常に同一戻り値（冪等 / Req 5.3, NFR 5.1）。
#   - 「非空の通常ファイルが 1 つ以上」を到達性 OK の基準とする（内容の正当性は検査しない）。
#     隠しファイル・サブディレクトリは到達性判定に算入しない（`find -type f -size +0c` 相当）。
#   - 「.claude/agents が単に不在」は missing であって indeterminate ではない。indeterminate は
#     test 自体が下せない真の I/O 異常に限定し、fail-open を濫用しない（design Decision 4）。
# Precondition: $1 は非空文字列（呼び出し側が $WT を渡す）。
sh_inspect_scaffolding() {
  local wt="${1:-}"

  # Precondition: 検査対象パスが空ならディレクトリ存否を確定できない真の異常として
  # indeterminate に倒す（fail-open / Req 3.1）。
  if [ -z "$wt" ]; then
    return 2
  fi

  local agents_dir="$wt/.claude/agents"
  local rules_dir="$wt/.claude/rules"

  # 親 `.claude` がファイル等で観測不能（dir でないのに存在する）な真の I/O 異常は
  # indeterminate に倒す。`.claude` が単に不在のケースは missing 経路で扱う（agents/rules
  # も不在として後段で missing 判定される）ため、ここでは弾かない。
  local claude_dir="$wt/.claude"
  if [ -e "$claude_dir" ] && [ ! -d "$claude_dir" ]; then
    return 2
  fi

  # 各ディレクトリに非空の通常ファイルが 1 つ以上あるかを判定する内部ヘルパ。
  # ディレクトリ不在 / 空 / 0 バイトファイルのみは NG（= missing 要素）。
  local agents_ok="missing"
  local rules_ok="missing"

  if [ -d "$agents_dir" ] && [ -n "$(find "$agents_dir" -type f -size +0c -print -quit 2>/dev/null)" ]; then
    agents_ok="ok"
  fi
  if [ -d "$rules_dir" ] && [ -n "$(find "$rules_dir" -type f -size +0c -print -quit 2>/dev/null)" ]; then
    rules_ok="ok"
  fi

  if [ "$agents_ok" = "ok" ] && [ "$rules_ok" = "ok" ]; then
    return 0
  fi

  echo "agents=${agents_ok} rules=${rules_ok}"
  return 1
}
