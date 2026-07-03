#!/usr/bin/env bash
# per-task-loop-prompt.sh — per-task loop の Implementer/Reviewer prompt builder
#
# family: per-task-loop / prefix: pt_（#500 で per-task-loop.sh から分割。family マニフェストは
#   per-task-loop.sh 冒頭ヘッダを参照）
#
# 用途:
#   per-task loop の Implementer / Reviewer 起動直前に埋め込む prompt 本文を組み立てる。
#   - build_per_task_implementer_prompt : task 単位の Implementer prompt を組み立て
#     （tasks.md 該当 task 抜粋 + design.md/requirements.md 参照指示 + redo_mode 分岐）
#   - build_per_task_reviewer_prompt    : task 単位の Reviewer prompt を組み立て
#     （diff range SHA 対 + round 別の観点指示 + extended フラグ分岐）
#   いずれも `cm_enabled` 通過時のみ context-map.md の内容を inline embed する。
#
# 配置先:
#   $HOME/bin/modules/per-task-loop-prompt.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - cm_enabled / cm_render_prompt_section（context-map.sh）を条件付きで呼ぶ。
#   - per-task-loop.sh（orchestrator）の pt_extract_learnings / pt_extract_findings_block /
#     pt_extract_debugger_section を呼ぶ（遅延束縛）。
#   - グローバル変数（$REPO_DIR / $SPEC_DIR_REL / $BODY 等）は watcher-config.sh / 本体 main loop。
#   - 外部 CLI: なし（純粋な文字列組み立て）。

# ─── build_per_task_implementer_prompt <task_id> [<redo_mode>] ───
#
# per-task Implementer 用の prompt を heredoc で組み立てて stdout に出力。
# 既存 `build_dev_prompt_a` の形式を踏襲しつつ、以下を明示する:
#
#   - 本起動で実装する task は <task_id> 1 件のみ（他の未完了 task に着手しない / Req 2.2）
#   - `tasks.md` の進捗マーカー更新 `- [ ]` → `- [x]` と `docs(tasks): mark <id> as done`
#     commit 規約（既存 #67 / #112 規約を流用 / Req 2.4, 2.5）
#   - `impl-notes.md` の `## Implementation Notes` 配下に `### Task <id>` を追記し、
#     先行 task の learnings は **改変・削除・並び替え禁止**（Req 4.1, 4.2, 4.4）
#   - 既存 learnings の inline 埋め込み（Req 4.3）
#   - PR 作成禁止 / spec 書き換え禁止（既存 Stage A 制約と同等）
#
# redo_mode 引数（Issue #305 で追加 / 既定 "initial"）:
#   - "initial"        : 初回 Implementer 起動。Findings / Fix Plan 注入ブロックを追加しない
#                        （既存 1 引数呼び出しと **完全に同一**の prompt を生成 / NFR 1.1）
#   - "after-round1"   : Reviewer round=1 reject 後の redo。`## 直前 round の Reviewer Findings`
#                        ブロックと `## Finding Closure Matrix の記録義務` ブロックを注入
#   - "after-debugger" : Debugger Gate 経由 round=3 の redo。上記 2 ブロックに加えて
#                        `## Debugger の Fix Plan` ブロックを注入 + Matrix 5 列目指示を追記
#   - 未知の値は安全側に "initial" へ fallback
#
# Requirements: 2.2, 2.3, 2.4, 2.5, 4.1, 4.2, 4.3, 4.4,
#               1.1, 1.2, 1.3, 1.4, 1.5, 4.3 (Issue #305),
#               NFR 1.1, NFR 3.1, NFR 4.1, NFR 4.2 (Issue #305)
build_per_task_implementer_prompt() {
  local task_id="$1"
  local redo_mode="${2:-initial}"
  # 安全側 fallback: 未知の値は initial 扱い
  case "$redo_mode" in
    initial|after-round1|after-debugger) ;;
    *) redo_mode=initial ;;
  esac

  local learnings
  learnings=$(pt_extract_learnings "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md")
  local learnings_block
  if [ -n "$learnings" ]; then
    learnings_block=$(cat <<EOF
## これまで完了した task の learnings（impl-notes.md より）

以下は先行 task の Implementer が記録した learning（採用方針 / 重要な判断 / 残存課題）です。
**本 task の実装で、命名規約・採用ライブラリ・運用判断との一貫性を維持するために必ず参照**
してください。各 \`### Task <id>\` セクションの本文を **改変・削除・並び替えしないこと**。

\`\`\`markdown
${learnings}
\`\`\`
EOF
)
  else
    learnings_block=$(cat <<'EOF'
## これまで完了した task の learnings（impl-notes.md より）

（先行 task の learnings はまだ存在しません。本 task が最初の per-task 実装です）
EOF
)
  fi

  # ─── redo_mode != initial 時のみ Findings / Fix Plan / Matrix 規約ブロックを構築 ───
  #
  # 注入ブロックは redo 経路（after-round1 / after-debugger）でのみ prompt 本文に追加され、
  # redo_mode=initial では空文字のまま heredoc に埋まる（= 既存 1 引数呼び出しと完全等価 / NFR 1.1）。
  #
  # NFR 3.1: 注入実施事実を grep 可能な 1 行で watcher ログに出力する。round 番号は本関数の引数
  # に含めず redo_mode に紐付ける形で省略する（after-round1 ≒ round=2 redo /
  # after-debugger ≒ round=3 redo の対応関係は run_per_task_loop 側で構造的に保証される）。
  # design.md 行 528 は `redo_mode=<mode> inject=<comma-sep-files> round=<N>` を例示するが、本
  # build 関数は round を引数で受け取らない設計（呼び出し側の wrapper で stage_label に
  # redo_mode を埋め込む / 後方互換性の単純化）のため round はログから省略する。
  local findings_block_section=""
  local debugger_block_section=""
  local closure_matrix_section=""
  # ─── #313: Context Map 注入ブロック（Req 3.1 / 3.5） ───
  # `cm_enabled` 通過時のみ context-map.md の内容を inline embed する markdown ブロックを
  # 生成。未設定 / off のときは空文字列のまま heredoc に展開され、prompt は本機能導入前と
  # byte 一致を保つ（NFR 1.1）。
  local context_map_block_section=""
  if cm_enabled; then
    context_map_block_section=$(cm_render_prompt_section "$task_id")
  fi
  if [ "$redo_mode" != "initial" ]; then
    local _inject_files=""
    # ── Reviewer Findings 注入（after-round1 / after-debugger 共通） ──
    local _review_notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
    local _findings_block
    if _findings_block=$(pt_extract_findings_block "$_review_notes_path"); then
      findings_block_section=$(cat <<EOF

## 直前 round の Reviewer Findings（review-notes.md より）

per-task Reviewer が直前 round で reject 判定を返した際の Findings セクションを以下に
inline で運びます。各 Finding の **Target / Category / Detail / Required Action** を確認し、
本起動で **必ず対応**してください（同じ指摘が次 round で再度 reject されないように、
fix commit + 追加テスト + 検証結果を Finding Closure Matrix に記録します。後述）。

\`\`\`markdown
${_findings_block}
\`\`\`
EOF
)
      _inject_files="review-notes"
    else
      findings_block_section=$(cat <<'EOF'

## 直前 round の Reviewer Findings（review-notes.md より）

(review-notes.md が見つかりません / 抽出失敗のため Findings の inline 注入を諦めました。
spec ディレクトリ配下の review-notes.md を直接読み、直前 round の Findings を参照してください)
EOF
)
      pt_log "task=$task_id redo_mode=$redo_mode inject=skipped reason=findings-extract-failed" >> "$LOG"
    fi

    # ── Debugger Fix Plan 注入（after-debugger のみ） ──
    if [ "$redo_mode" = "after-debugger" ]; then
      local _debugger_notes_path="$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md"
      local _debugger_block
      if _debugger_block=$(pt_extract_debugger_section "$_debugger_notes_path" "$task_id"); then
        debugger_block_section=$(cat <<EOF

## Debugger の Fix Plan（debugger-notes.md より）

Debugger サブエージェントが当該 task について生成した Fix Plan を以下に inline で運びます。
\`### 根本原因\` / \`### 修正手順\` / \`### 検証方法\` / \`### 残存リスク\` を読み、本起動で
修正手順を順に実施し、検証方法で挙動を確認してください。Debugger は **コード修正権限を
持たない**ため、Fix Plan の実装は本起動の Developer が担います。

\`\`\`markdown
${_debugger_block}
\`\`\`
EOF
)
        if [ -n "$_inject_files" ]; then
          _inject_files="${_inject_files},debugger-notes"
        else
          _inject_files="debugger-notes"
        fi
      else
        debugger_block_section=$(cat <<EOF

## Debugger の Fix Plan（debugger-notes.md より）

(debugger-notes.md または \`## Task ${task_id}\` セクションが見つかりません / 抽出失敗
のため Fix Plan の inline 注入を諦めました。spec ディレクトリ配下の debugger-notes.md を
直接読み、当該 task の Fix Plan を参照してください)
EOF
)
        pt_log "task=$task_id redo_mode=$redo_mode inject=skipped reason=debugger-section-not-found" >> "$LOG"
      fi
    fi

    # ── 注入実施を 1 行で記録（NFR 3.1） ──
    if [ -n "$_inject_files" ]; then
      pt_log "task=$task_id redo_mode=$redo_mode inject=$_inject_files" >> "$LOG"
    fi

    # ── Finding Closure Matrix の記録義務（redo 経路共通） ──
    #
    # 詳細規約は developer.md の「per-task retry 時の Finding Closure Matrix 記録義務」節
    # （Issue #305 の task 7 で追加予定）を canonical source として参照する。本 prompt では
    # 規約への参照と最小限の指示を 1〜2 段落で運ぶ。
    if [ "$redo_mode" = "after-debugger" ]; then
      closure_matrix_section=$(cat <<EOF

## Finding Closure Matrix の記録義務（per-task retry 経路）

本起動は per-task retry 経路（redo_mode=${redo_mode}）です。直前 round の Reviewer Findings
（および Debugger Fix Plan）に対する対応状況を、**Finding Closure Matrix** として
\`${SPEC_DIR_REL}/impl-notes.md\` の \`### Task ${task_id}\` セクション末尾に追記してください。
規約詳細は \`.claude/agents/developer.md\` の「per-task retry 時の Finding Closure Matrix
記録義務」節を canonical source として参照すること。

Matrix の各行には直前 round の Reviewer Finding ごとに **Finding / Target / Fix Commit /
Added/Updated Test / Verification** の 4 項目（5 列）を対応付け、本起動は Debugger Gate
経由 round=3 のため **5 列目「Fix Plan Step」**（対応する Debugger Fix Plan の修正手順番号）も
**必ず追記**してください。fix commit が存在しない Finding には「未対応」「対応不可（理由）」
「次 round へ持ち越し」のいずれかを Fix Commit 列で明示します。先行 task の Matrix および
先行 round の Matrix 既存行は **改変・削除・並び替え禁止**（新規 round の Matrix は新規
見出しで追加）。
EOF
)
    else
      closure_matrix_section=$(cat <<EOF

## Finding Closure Matrix の記録義務（per-task retry 経路）

本起動は per-task retry 経路（redo_mode=${redo_mode}）です。直前 round の Reviewer Findings
に対する対応状況を、**Finding Closure Matrix** として
\`${SPEC_DIR_REL}/impl-notes.md\` の \`### Task ${task_id}\` セクション末尾に追記してください。
規約詳細は \`.claude/agents/developer.md\` の「per-task retry 時の Finding Closure Matrix
記録義務」節を canonical source として参照すること。

Matrix の各行には直前 round の Reviewer Finding ごとに **Finding / Target / Fix Commit /
Added/Updated Test / Verification** の 4 項目（4 列）を対応付け、fix commit が存在しない
Finding には「未対応」「対応不可（理由）」「次 round へ持ち越し」のいずれかを Fix Commit
列で明示します。先行 task の Matrix および先行 round の Matrix 既存行は **改変・削除・
並び替え禁止**（新規 round の Matrix は新規見出しで追加）。
EOF
)
    fi
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
本起動は **per-task ループ**（PER_TASK_LOOP_ENABLED=true）の下で、\`tasks.md\` の
**1 件の task のみ** を fresh context で実装するために起動されました。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（${BASE_BRANCH} から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## 本起動で実装する task

- **対象 task ID**: \`${task_id}\`
- 本起動では \`tasks.md\` の **${task_id} 1 件のみ** を実装します。他の未完了 task には
  一切着手しないこと（次 task は別の fresh Implementer 起動で消化されます）

## 進め方

1. developer サブエージェントを起動し、対象 task \`${task_id}\` を実装＋テスト＋commit する
   - 入力: \`${SPEC_DIR_REL}/requirements.md\` / \`${SPEC_DIR_REL}/design.md\` / \`${SPEC_DIR_REL}/tasks.md\`
   - design.md / tasks.md は人間レビュー済みで **書き換え禁止**（矛盾は impl-notes.md の
     「確認事項」に記載するに留める）
   - tasks.md の対象 task の \`_Requirements:_\` / \`_Boundary:_\` に従う
   - 規約は CLAUDE.md に従う

2. **進捗マーカー更新**（既存 #67 / #112 規約 + Issue #164「1 commit = 1 task ID」厳格化）:
   - 対象 task の \`- [ ] ${task_id}\` 行を \`- [x] ${task_id}\` に書き換える
   - 子タスク（例: ${task_id}.1）を完了した場合、親 task（${task_id} の親、例: ${task_id%.*}）
     配下の全子タスクが \`- [x]\` になったタイミングで親も \`- [x]\` に昇格する
   - 進捗マーカー更新は **専用 commit**: \`docs(tasks): mark <id> as done\`
     - 当該 commit には \`tasks.md\` 以外のファイルを含めない
   - **【重要 / Issue #164】1 つの marker commit には 1 つの task ID のみを含めること**:
     - 1 つの \`docs(tasks): mark <id> as done\` commit には **必ず 1 つの task ID のみ**
       を含めること（per-task Reviewer の diff range 解決が task ID 単位で行われるため）
     - **親 task の完了昇格も別 commit に分割**する。例: 子 \`1.1\` 完了で親 \`1\` も
       全完了になる場合、まず \`docs(tasks): mark 1.1 as done\` を 1 commit で作成し、
       続けて \`docs(tasks): mark 1 as done\` を **別 commit** として続けて作成する
     - **連記禁止例（NG）**: \`docs(tasks): mark 1 / 1.1 as done\` /
       \`docs(tasks): mark 1, 1.1 as done\` のように複数 ID を 1 commit にまとめる
       subject 表記は禁止
     - 連記 marker commit を作成すると、per-task Reviewer の diff range 解決が単記 ID で
       一致しなくなり \`diff-range-resolve-failed\` を起こす可能性がある（watcher 側で
       fallback 解決は試行するが、canonical は単記分割のみ）
   - 書き換え禁止領域: タスク本文 / \`_Requirements:_\` / \`_Boundary:_\` / \`_Depends:_\` /
     タスク順序 / 親タスクのインデント / deferrable 印 \`- [ ]*\`

3. **learning 追記**（per-task ループの中核 / Req 4.1, 4.2, 4.4）:
   - \`${SPEC_DIR_REL}/impl-notes.md\` の \`## Implementation Notes\` セクション配下に
     \`### Task ${task_id}\` 見出しを **追加**（既存セクションが無ければ作成）し、本 task の
     learning を簡潔に記録する:
     - 採用方針（1 行）
     - 重要な判断（1〜3 行）
     - 残存課題（次 task に影響する事項。なければ「なし」）
   - **先行 task の \`### Task <id>\` 見出し（既存の learnings）は改変・削除・並び替えしない**
   - \`## Implementation Notes\` セクション **外** の既存記述（補足ノート / 確認事項など）
     には触れない

${learnings_block}

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- 既存のテストを壊さないこと
- 不明点は推測せず、impl-notes.md の「確認事項」セクションに列挙すること
- **PR は作成しないこと**（Reviewer / PjM は別 stage で起動されます）
- **本 task 以外の未完了 task には一切着手しないこと**
- requirements.md / design.md / tasks.md 本文の書き換えは禁止（tasks.md の進捗マーカー
  \`- [ ]\` → \`- [x]\` のみ例外）

## 既存 commit の温存

本 worktree は既存 commit を温存した状態でチェックアウトされています。

- 作業前に \`git log --oneline ${BASE_BRANCH}..HEAD\` で既存 commit を確認すること
- \`git reset\` / \`git rebase\` / branch の切り替えは **禁止**
- 既存 commit と矛盾する変更が必要な場合は、既存 commit を打ち消す追加 commit を積むか、
  impl-notes.md の「確認事項」に矛盾内容を記載して人間判断を仰ぐ
${findings_block_section}${debugger_block_section}${closure_matrix_section}${context_map_block_section}
EOF
}

# ─── build_per_task_reviewer_prompt <task_id> <range_start_sha> <range_end_sha> <round> <prev_result> [<extended>] ───
#
# per-task Reviewer 用の prompt を heredoc で組み立てて stdout に出力。
# 既存 `build_reviewer_prompt` の形式を踏襲しつつ、以下を明示する:
#
#   - 判定対象 diff range は `<range_start>..<range_end>` のみ（HEAD 全体ではない / Req 3.2）
#   - 判定 AC は当該 task の `_Requirements:_` 列挙分のみ（全 AC verify は Stage B / Req 3.3）
#   - `_Boundary:_` 違反は depth に関わらず常に reject 対象
#   - 既存 reviewer.md の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）と
#     RESULT 行 / review-notes.md 出力契約を流用
#   - 第 6 引数 `extended`（"true"/"false"、省略時 "false"）: watcher が marker 後の
#     post-marker commit を検出して HEAD ベースに range を拡張したか否か（Issue #304 Req 3.3）
#
# Requirements: 3.1, 3.2, 3.3
build_per_task_reviewer_prompt() {
  local task_id="$1"
  local range_start="$2"
  local range_end="$3"
  local round="$4"
  local prev_result="$5"
  # Issue #304 Req 3.3: 第 6 引数 `extended` は省略時 "false"（既存呼び出し互換）。
  # watcher が post-marker commit を検出して range を HEAD まで拡張した場合のみ "true" が
  # 渡される。値は prompt 本文の `range_extended:` 行と extended-range 説明文に反映される。
  local extended="${6:-false}"

  # Issue #304 Req 3.3: extended=true 時の追加説明 block（normal 経路では空文字列）。
  # heredoc 中で条件分岐すると bash 構文が崩れるため、変数で差し込む方式を採用。
  # 変数の中身は外側の `cat <<EOF` で変数展開された後の最終 prompt にそのまま埋め込まれる。
  # quoted heredoc（'EXTENDED_EOF'）を使うことで $ / ` / \ が一切解釈されず、markdown の
  # バッククォートも literal で保持される（外側 heredoc の二重 escape 不要）。
  # ─── #313: Context Map 注入ブロック（Req 3.2 / 3.5） ───
  # `cm_enabled` 通過時のみ context-map.md の内容を inline embed する markdown ブロックを
  # 生成。未設定 / off のときは空文字列のまま heredoc に展開され、prompt は本機能導入前と
  # byte 一致を保つ（NFR 1.1）。
  local context_map_block_section=""
  if cm_enabled; then
    context_map_block_section=$(cm_render_prompt_section "$task_id")
  fi

  local extended_explanation=""
  if [ "$extended" = "true" ]; then
    extended_explanation=$(cat <<'EXTENDED_EOF'

### Extended range（watcher による range 拡張通知）

watcher が当該 task の `docs(tasks): mark` marker commit より後ろに **未レビューの
post-marker commit** を検出したため、env `POST_MARKER_RECOVERY_MODE=extend-range` の
recovery 経路により range_end を marker SHA ではなく **HEAD まで拡張** しています
（Issue #304 Req 3.3）。

上記 `range_end_sha` は marker commit ではなく **HEAD の SHA** であり、上記
`range_start_sha..range_end_sha` の範囲には marker 後に積まれた修正 commit も含まれます。
extended 状態でも本 Reviewer の判定基準は変わりません（range 内 commit のみを判定根拠と
してください）。
EXTENDED_EOF
)
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
本起動は **per-task ループ**（PER_TASK_LOOP_ENABLED=true）の下で、直前の Implementer が
完了した **1 件の task の commit 範囲のみ** を独立 context でレビューするために起動されました。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- REPO  : ${REPO}

## 作業ブランチ / spec ディレクトリ
- BRANCH       : ${BRANCH}
- BASE_BRANCH  : ${BASE_BRANCH}
- SPEC_DIR_REL : ${SPEC_DIR_REL}
- ROUND        : ${round}
- PREV_RESULT  : ${prev_result}

## 判定対象の task / diff range

- **対象 task ID**: \`${task_id}\`
- **range_start_sha**: \`${range_start}\` （= 直前の \`docs(tasks): mark\` commit、または初回時は \`${BASE_BRANCH}\` の SHA）
- **range_end_sha**:   \`${range_end}\`   （= 当該 task の \`docs(tasks): mark ${task_id} as done\` commit、ただし extended=true の場合は HEAD）

reviewer は **本 range のみ** を判定対象としてください。HEAD 全体は対象外（全体観点は
最終 Stage B Reviewer が別途担当します）。

> **Warning（Issue #304 Req 3.2）**: 上記 \`range_start_sha..range_end_sha\` の **外側** に
> ある commit（HEAD が range_end より後ろにある場合等）は本 Reviewer の **判定対象外** です。
> range 外 commit の内容を理由に approve / reject を出してはいけません。HEAD 全体観点は
> 最終 Stage B Reviewer が担当します。本 Reviewer は \`range_start_sha..range_end_sha\` 内
> commit のみを判定根拠としてください。

## 判定対象 SHA range（machine-parseable）

以下は watcher → Reviewer 間の range 引き継ぎを機械パース可能な形で再掲した block です
（Issue #304 Req 3.1）。Reviewer は本 block の値を判定対象 SHA range の正本として扱って
ください。

\`\`\`
range_start_sha: ${range_start}
range_end_sha:   ${range_end}
range_extended:  ${extended}
\`\`\`
${extended_explanation}

## 必読ファイル

reviewer サブエージェントは着手前に以下を必ず Read してください:

- \`CLAUDE.md\`（特に「テスト規約」と「禁止事項」）
- \`${SPEC_DIR_REL}/requirements.md\`（EARS 形式の AC、numeric ID）
- \`${SPEC_DIR_REL}/tasks.md\`（特に対象 task \`${task_id}\` の \`_Requirements:_\` / \`_Boundary:_\`）
- \`${SPEC_DIR_REL}/impl-notes.md\`（Developer の補足。\`### Task ${task_id}\` の learning を含む）
- \`${SPEC_DIR_REL}/design.md\`（存在する場合）

## 差分の取得（reviewer が Bash で実行）

reviewer は **必ず自分で** Bash で以下を実行し、本 task の commit 範囲だけを取得してください:

1. 全体把握（変更ファイル一覧と統計）:
   \`\`\`bash
   git diff --stat ${range_start}..${range_end}
   git log --oneline ${range_start}..${range_end}
   \`\`\`
2. ファイル単位の詳細差分（必要に応じて変更ファイルごとに実行）:
   \`\`\`bash
   git diff ${range_start}..${range_end} -- <path>
   \`\`\`

## 判定基準（per-task ループの判定 depth 制約）

reviewer.md の **3 カテゴリ**（AC 未カバー / missing test / boundary 逸脱）のみで判定します。
per-task ループでは判定 depth が以下に絞り込まれます:

- **判定対象 AC**: 当該 task \`${task_id}\` の \`_Requirements:_\` で列挙された numeric ID **のみ**
  - それ以外の AC が当該 diff で未カバーであっても reject 理由にしないこと
  - 全 AC verify は最終 Stage B Reviewer が HEAD 全体で実施するため、本 Reviewer では
    範囲外 AC を理由とした reject を出さない
- **\`_Boundary:_\` 違反**: depth に関わらず **常に reject 対象**（task 単位境界の逸脱検出が
  本ループの主目的）

## 進め方

reviewer サブエージェントを起動し、以下を判定して \`${SPEC_DIR_REL}/review-notes.md\` に
書き出してください（reviewer.md の出力契約に従う）。

- 最終行は必ず \`RESULT: approve\` または \`RESULT: reject\` で終わること（lowercase 完全一致）
- 装飾（バッククォート / bullet / blockquote / 行末プローズ）禁止

## 制約
- requirements.md / design.md / tasks.md / 既存実装コード / テストコードを書き換えないこと
- \`git add\` / \`git commit\` / \`git push\` / \`gh\` を実行しないこと
- スタイル / 命名 / lint / フォーマット観点での reject はしないこと
${context_map_block_section}
EOF
}

