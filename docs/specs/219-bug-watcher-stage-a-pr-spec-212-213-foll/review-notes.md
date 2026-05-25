# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-25T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-219-impl-bug-watcher-stage-a-pr-spec-212-213-foll
- HEAD commit: c62671f36fb2fe1123208d51bcce67de4139172a
- Compared to: main..HEAD（実差分は merge-base 6df7773..HEAD で判定。main..HEAD に現れる
  spec 221 ファイル群・`local-watcher/test/stage_a_verify_round1_defer_test.sh` の削除、
  README 変更は本ブランチ由来ではなく、merge-base 以降に main が PR #222 / #223 で
  進んだことによる artifact のため判定対象外）

## Verified Requirements

- 1.1 — `build_dev_prompt_a`（issue-watcher.sh L3346-3350）: 制約節の `**PR は作成しないこと**`
  を維持しつつ、後段提示文「Reviewer の approve 後にオーケストレーターが PjM を起動して PR を
  作成します」を「本ステージのゴールは impl-notes.md の保存まで…一切起動・実行しないでください」へ
  置換し、impl PR 作成を促す表現を排除（L3242 / L3259）
- 1.2 — `build_dev_prompt_a` 制約節（L3351）に `**reviewer / project-manager サブエージェントを
  起動しないこと**` を追加。Reviewer 起動表現を除去
- 1.3 — 同上（同一制約行で project-manager サブエージェント起動も禁止明記）
- 1.4 — 共有プロンプトヘッダ（L3326-3327）の主語を「Claude Code オーケストレーター」から
  「Stage A（PM + Developer）担当のサブオーケストレーター」へ弱化し、後段フロー完遂を促す文を
  削除。当該 `cat <<EOF` は impl / impl-resume 双方が通る単一ヘッダで、design-less impl
  fallback でも同一の限定表現が適用される
- NFR 1.1（Req 1 範囲）— 変更は heredoc テキストのみで制御フロー・シグネチャ・戻り値は不変

（以下の Requirement は対応実装・テストが diff にも既存コードにも存在せず未検証）

- 2.1, 2.2, 2.3, 2.4, 2.5 — 未カバー（後述 Finding 1）
- 3.1, 3.2, 3.3, 3.4, 3.5 — 未カバー（後述 Finding 1）
- 4.1, 4.2, 4.3 — 未カバー（後述 Finding 1）
- NFR 2.1, 2.2, 3.1, 3.2 — 未カバー（後述 Finding 1）

## Findings

### Finding 1
- **Target**: 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2, 4.3, NFR 2.1, NFR 2.2, NFR 3.1, NFR 3.2
- **Category**: AC 未カバー
- **Detail**: 本ブランチの実差分（6df7773..HEAD）は `build_dev_prompt_a` のプロンプト
  テキスト変更（Requirement 1 / tasks.md task 1.1 のみ）に限定されている。tasks.md は task 1 /
  1.1 のみ `- [x]` で、task 2〜6 は未着手（`- [ ]`）のまま。requirements.md / design.md /
  tasks.md が要求する以下が diff・既存コードのいずれにも存在しない:
  - Requirement 2（越境観測）: `stage_a_crossing_probe` 関数、`stage-a-crossing:` ログ、
    グローバル変数 `STAGE_A_CROSSING_DETECTED` / `STAGE_A_CROSSING_PR`、`run_impl_pipeline`
    の Stage A 完了直後の呼び出し挿入が **いずれも未実装**（grep で 0 件）
  - Requirement 3（spec 完全性保証）: `_spec_missing_artifacts` /
    `spec_artifacts_completeness_guard` / `_spec_create_docs_pr` / `_spec_escalate_incomplete`、
    `spec-completeness:` ログ、pipeline 末尾の結線が **いずれも未実装**（grep で 0 件）
  - Requirement 4（#213 整合・docs-only 補完経路）: 上記 C3 群に依存するため未実装
  - README task 6.1（NFR 3.2 観測の運用ドキュメント化）: 本ブランチは README を変更していない
    （merge-base..HEAD の README 差分は空）
  - impl-notes.md は task 1.1 のみを記載し、末尾に `STATUS:` 行が無い（partial 宣言なし）。
    よって partial 経路の Reviewer 免除（#148）は適用されず、全 AC を判定対象とした
- **Required Action**: tasks.md の task 2〜6 を実装する。具体的には design.md の
  Components and Interfaces / File Structure Plan に従い (a) `stage_a_crossing_probe`
  新規追加 + `run_impl_pipeline` 結線（Req 2）、(b) `_spec_missing_artifacts` /
  `spec_artifacts_completeness_guard` / `_spec_create_docs_pr` / `_spec_escalate_incomplete`
  追加 + pipeline 末尾結線（Req 3 / 4）、(c) README「Stage Checkpoint (#68)」節への追記
  （Req 2.5 / 3.5 / NFR 1.1 / 1.2）を行い、対応する fixture / スモーク検証（task 6.2 相当、
  少なくとも `STAGE_CHECKPOINT_ENABLED=false` で `stage-a-crossing:` / `spec-completeness:`
  ログが 1 行も出ないことの確認）を impl-notes.md に記録すること。すべてのタスク完了後に
  tasks.md の checkbox を更新し直すこと

## Summary

Requirement 1（AC 1.1-1.4）は `build_dev_prompt_a` のプロンプト責務限定でカバー済みだが、
Requirement 2（越境観測）/ 3（spec 完全性保証）/ 4（#213 整合）および NFR 2.1/2.2/3.1/3.2 に
対応する実装・テストが diff・既存コードのいずれにも存在しない（tasks.md task 2〜6 未着手、
関連関数・ログ・README 追記すべて 0 件）。AC 未カバーにつき reject。

（round=1 の判定は reject であった。下記 round=2 で再判定する。）

---

<!-- idd-claude:review round=2 model=claude-opus-4-7 timestamp=2026-05-25T12:00:00Z -->

## Reviewed Scope (round=2)

- Branch: claude/issue-219-impl-bug-watcher-stage-a-pr-spec-212-213-foll
- HEAD commit: b88c9f6（`git log --oneline 6df7773..HEAD` 先頭）
- Compared to: merge-base 6df7773..HEAD（main..HEAD には PR #222 / #223 で main が進んだ
  artifact が混じるため、本ブランチ由来差分は merge-base で判定 / round=1 注記を踏襲）
- 実差分: `local-watcher/bin/issue-watcher.sh`（+391 行）/ `README.md`（+30 行）/
  `tasks.md`（全 task 1〜6 を `- [x]`）/ `impl-notes.md`（task 2〜6 是正記録 + `STATUS: complete`）/
  `test-fixtures/spec-complete/`（requirements/review/impl-notes）/
  `test-fixtures/spec-incomplete-merged/`（impl-notes のみ）
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が **存在しない** ため
  opt-out として解釈。通常の 3 カテゴリ判定のみ実施（flag 観点の細目は適用しない）

## Verified Requirements (round=2)

round=1 で未カバーだった Requirement 2 / 3 / 4 および関連 NFR が、本 round で実装・検証された。
Reviewer は新規 5 関数を awk 抽出し、`stage_checkpoint_find_impl_pr` と補助関数をモック化した
関数単位スモーク（gate-off / rc=0/1/2 / fixture 判定 / MERGED-trigger）を独立に再実行して
裏取りした。

- 1.1〜1.4 / NFR 1.1（Req 1 範囲） — round=1 で verified 済み。round=2 でも該当 heredoc
  差分（L3593 / L3610 / L3678 / L3702 付近）が温存されていることを確認
- 2.1 — `stage_a_crossing_probe`（issue-watcher.sh L1314〜）を新規追加し、`run_impl_pipeline`
  の Stage A 完了直後 2 経路（per-task loop の `✅ Stage A 完了（per-task loop）` 直後 /
  通常 Developer 経路の `✅ Stage A 完了` 直後）に結線。`stage_checkpoint_find_impl_pr` を
  再利用して先行 PR 有無を観測
- 2.2 / 2.3 — 検出時のみ `sc_log "stage-a-crossing: detected pr=#<N> state=<S> branch=<BRANCH>
  issue=#<NUMBER>"` を出力（スモーク T4 で `pr=#218 state=MERGED branch=feat issue=#219` を確認）
- 2.4 — グローバル変数 `STAGE_A_CROSSING_DETECTED` / `STAGE_A_CROSSING_PR` を set
  （`run_impl_pipeline` スコープで `local` 宣言 + SC2034 抑制、既存 `START_STAGE` と同パターン）。
  `spec_artifacts_completeness_guard` が `crossing=<yes|no> crossing-pr=#<N>` として実 read する
  ことを最終スモークで確認（`crossing=yes crossing-pr=#218`）
- 2.5 / NFR 1.1 — `STAGE_CHECKPOINT_ENABLED != "true"` で冒頭即 return 0。スモーク T1 で
  `=false` 時に `stage-a-crossing:` / `spec-completeness:` ログが **0 行**であることを確認
- 3.1 / 3.5 — `spec_artifacts_completeness_guard` を pipeline 末尾 2 経路（Stage C 冪等ガード
  停止経路 L5311 直前 / Stage C 成功経路 L5356 直前）に結線。`_spec_missing_artifacts` が
  空（標準構成充足）なら追加処理なしで return 0（スモーク T2: spec-complete fixture で空出力）
- 3.2 — MERGED かつ req/review 欠落のときのみ `_spec_create_docs_pr` を起動（スモーク：
  state=MERGED で `trigger=merged` + `_spec_create_docs_pr` 呼び出し、missing=`requirements review`
  がクリーンに渡ることを確認）
- 3.3 — `_spec_create_docs_pr` 失敗時に `_spec_escalate_incomplete`（`needs-decisions` 付与 +
  Issue コメント 1 件）へフォールバック
- 3.4 / NFR 3.2 — `_spec_missing_artifacts` が `spec-completeness: missing=<...>
  missing-design=<...> dir=<...>` を既存ログ書式で出力（スモーク T3: incomplete fixture で
  `missing=requirements review missing-design=design tasks` をログに記録、かつ stdout は
  補完対象 `requirements review` のみクリーン出力）
- 4.1 — `stage_c_existing_pr_guard` 本体・呼び出しに `+`/`-` 差分なし（diff 上は新規コメント中の
  関数名参照のみ）。完全性保証は同ガードの **後段独立経路**として配置。MERGED 以外
  （OPEN/CLOSED/none）では補完を起動せず `action=none reason=not-merged` で記録のみ（スモーク確認）
- 4.2 — docs-only PR のみ作成し新規 impl PR を作らない。head は impl ブランチと別系統
  `claude/issue-<NUMBER>-docs-<SLUG>` のため #213 MERGED ガード（`--head $BRANCH`）と衝突しない
- 4.3 — `_spec_create_docs_pr` が `--head claude/issue-<N>-docs-<SLUG>` / `--base $BASE_BRANCH`
  / `ready-for-review` 非付与の docs-only 追従 PR を作成（impl PR と区別 / Decision D3）
- NFR 1.2 — 新規 env var を足さず `STAGE_CHECKPOINT_ENABLED` 相乗り（README 表・節の記述と整合）
- NFR 1.4 — `stage_a_crossing_probe` / `spec_artifacts_completeness_guard` ともに常に return 0
  （全スモークケースで rc=0）。pipeline の return 値を変えない
- NFR 1.5 — 新規ログは `sc_log` で追加するのみ。既存ログ行の書式変更なし
- NFR 2.1 — `_spec_create_docs_pr` が作成前に `gh pr list --head <docs-branch> --state all` で
  既存 docs PR を再観測し、あれば `result=skip-existing` で作成しない（実装確認）
- NFR 2.2 — `_spec_escalate_incomplete` が `gh issue view --json labels` の `needs-decisions`
  既付与チェックでコメント冪等化（実装確認）
- NFR 3.1 — `stage-a-crossing:` prefix で grep 可能
- NFR 3.2 — `spec-completeness:` prefix で grep 可能

### 静的解析 / 構文（Reviewer 再実行）
- `bash -n local-watcher/bin/issue-watcher.sh` → syntax OK
- `shellcheck local-watcher/bin/issue-watcher.sh` → SC2317 (info) のみで本変更による新規警告
  ゼロ（SC2317 を除外した出力は空）。`STAGE_A_CROSSING_*` の SC2034 は dynamic scope read 実装 +
  `# shellcheck disable=SC2034`（`START_STAGE` 先例踏襲）で解消済み

### Boundary 確認
- 変更は tasks.md の各 `_Boundary:_` 宣言（`build_dev_prompt_a` / `stage_a_crossing_probe` /
  `_spec_missing_artifacts` / `_spec_create_docs_pr` / `_spec_escalate_incomplete` /
  `spec_artifacts_completeness_guard` / `run_impl_pipeline`）と README に限定。design.md の
  D1〜D4 / Components 契約（gate で即 return / 検出時のみログ / docs-only 別 head /
  補完不能時のみ escalate / `stage_c_existing_pr_guard` 不変）に逸脱なし。boundary 逸脱なし

## Findings (round=2)

なし（round=1 Finding 1 の全 Target が解消済み。新規の reject 理由も検出せず）

## Summary (round=2)

round=1 で未カバーだった Requirement 2（越境観測）/ 3（spec 完全性保証）/ 4（#213 整合）
および NFR 2.1/2.2/3.1/3.2 が、design.md の Components / Decisions D1〜D4 に厳密に従って実装・
結線され、Reviewer の独立スモーク（gate-off no-op / rc 分岐 / fixture 判定 / MERGED-trigger /
越境フラグ引き継ぎ）で裏打ちされた。`stage_c_existing_pr_guard` は不変（Req 4.1 退行なし）、
`STAGE_CHECKPOINT_ENABLED != true` で完全等価（NFR 1.1 / Req 2.5）、shellcheck 新規警告ゼロ。
全 numeric AC をカバーし boundary 逸脱なし。approve。

RESULT: approve
