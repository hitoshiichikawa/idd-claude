# Implementation Notes (#238)

## Implementation Notes

### Task 1

- **採用方針**: 新規モジュール `local-watcher/bin/modules/scaffolding-health.sh` を `stage-a-verify.sh` と同形式（冒頭コメント / 3 段 prefix logger / `set -euo pipefail` 非宣言・関数定義のみ）で作成し、logger 3 関数（`sh_log` / `sh_warn` / `sh_error`）と検査純関数 `sh_inspect_scaffolding` を実装した。
- **重要な判断**:
  - `sh_inspect_scaffolding` の非空判定は `find "$dir" -type f -size +0c -print -quit` で行い、`*.md` 限定にせず将来のファイル種別変更に頑健にした（design Decision 4 準拠）。
  - indeterminate（戻り値 2）へ倒すのは「`.claude` が通常ファイル等で存在するのに dir でない真の I/O 異常」と「検査対象パスが空文字列」の 2 ケースに限定。「`.claude`/agents が単に不在」は missing（戻り値 1 + サマリ `agents=missing rules=ok` 等）として扱い、fail-open を濫用しない（design L252 の設計意図）。
  - stdout は missing 時のみサマリを 1 行出力。full / indeterminate 時は無出力（design の stdout 契約）。
- **残存課題**: なし（次 task への影響なし）。本 task は関数定義のみで、本体結線（Config env / REQUIRED_MODULES / preflight gate call site / `--doctor` dispatch）は task 2・3、README 更新は task 4 が担当する。`sh_preflight_gate` / `_sh_emit_visibility_signal` / `sh_doctor_*` は本モジュールに後続 task で追加される（モジュール冒頭コメントにも明記済み）。

## Round 2 是正（Reviewer reject 対応）

Round 1 の Reviewer は「実装が task 1（純検査関数の骨格）のみで止まっており、preflight gate・可視シグナル・HALT 切替・fail-open 消費・doctor サブコマンド一式・本体結線（task 2/3/4）が未実装」として reject した（review-notes.md Finding 1〜6）。本 Round 2 で残タスク（task 2 / 2.1 / 2.2 / 3 / 3.1 / 3.2 / 4 / 4.1）と deferrable test（task 5）を実装した。

### Finding 1 + 3（task 2.1）: gate と可視シグナル

- `_sh_emit_visibility_signal`（$1=欠落サマリ）を `scaffolding-health.sh` に追加。本文に機械可読マーカー `<!-- scaffolding-health:missing -->` を埋め、投稿前に `gh issue view --json comments --jq '.comments[].body'` で同マーカーの既存有無を確認して重複投稿を抑止（冪等 / Req 5.3 / NFR 5.1）。マーカー確認失敗時は `sh_warn` で警告のうえ fail-open で投稿を試みる（取りこぼしより重複が安全）。投稿失敗も `|| sh_warn` で吸収し常に 0 を返す。
- `sh_preflight_gate`（$1=worktree）を追加。`summary=$(sh_inspect_scaffolding "$1") || rc=$?` で戻り値とサマリ stdout を両方取り込み、`set -e` でも落ちないよう `|| rc=$?` で捕捉。分岐:
  - full（0）→ `sh_log "outcome=pass ..."` を 1 行出して return 0（NO-OP。tracked repo はここに到達し WARN を出さない / Req 1.5 / 5.1 / NFR 1.1）。
  - missing（1）→ loud `sh_warn "足場欠落を検出: <サマリ>"`（Req 1.2）＋ `_sh_emit_visibility_signal "<サマリ>"`（Req 1.3）。その後 `case "${SCAFFOLDING_HEALTH_HALT:-off}" in on) ... ;; *) ... ;; esac` の厳密一致判定（stage-a-verify.sh の env 判定パターン踏襲）で `on` のみ `outcome=halt` + return 1（HALT）、それ以外（off/未設定/空/true/On/typo）は `outcome=continue` + return 0（既定 = 可視化のみ / Req 2.1 / 2.3）。
  - indeterminate（2）→ `sh_warn` で確定不能の事実を可視出力（Req 3.2）し `outcome=continue scaffolding=indeterminate` をログして return 0（fail-open。HALT opt-in でも停止に倒さない / Req 3.1 / 3.3）。
- 1 回の呼び出しで必ず 1 行以上の `scaffolding-health:` ログを出す（silent 禁止 / Req 1.4 / NFR 2.1）。全分岐で `sh_log` を出すことで担保。

### Finding 2 + 5（task 2.2）: 本体結線

- Config ブロック（`STAGE_A_VERIFY_*` 直後）に `SCAFFOLDING_HEALTH_HALT="${SCAFFOLDING_HEALTH_HALT:-off}"` を追加。既定挙動（可視化のみ・進行継続）が本機能導入前と user-observable に同一である旨をコメントで明記（NFR 1.1）。
- `REQUIRED_MODULES` 配列末尾に `"scaffolding-health.sh"` を 1 要素追加（これで本体から source される）。
- `_slot_run_issue` 内、`_worktree_inject_claude "$SRC_REPO_DIR" "$WT"` の直後・`_hook_invoke` の直前に call site を挿入（design「call site 契約」準拠）。`_slot_run_issue` は per-slot subshell 内で動く**関数**なので `return 0` が正しく機能する（既存の `_slot_mark_failed; return 1` 脱出パターンと同一文脈）。
- **採用した設計判断（Decision 3）**: HALT 分岐では `gh issue edit ... --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" >/dev/null 2>&1 || true` で claim 系ラベルを除去して `auto-dev` に戻す。`claude-failed` は付けない（足場欠落は「失敗」ではなく「人間判断待ち」/ Req 2.2）。`_slot_mark_failed` の label 操作を参考にしたが `--add-label "$LABEL_FAILED"` は付与しない点が相違。`|| true` で fail-open。`slot_log` で人間判断待ちを記録して `return 0`。
- 既存 env 名 / ラベル契約 / exit code 意味 / ログ書式は変更していない（新 prefix `scaffolding-health:` と env `SCAFFOLDING_HEALTH_HALT` 1 個の追加のみ / Req 5.2）。

### Finding 4（task 3.1 + 3.2）: doctor サブコマンド一式

- `sh_doctor_check_scaffolding`（`sh_inspect_scaffolding "$REPO_DIR"` 流用 / Req 4.2）、`sh_doctor_check_clis`（`command -v gh jq flock git claude` / Req 4.3）、`sh_doctor_check_labels`（`gh label list --json name` + jq で必須ラベル集合存否 / read-only / Req 4.4）、`sh_doctor_check_base_branch`（`git -C "$REPO_DIR" rev-parse --verify --quiet "origin/$BASE_BRANCH"` / read-only / Req 4.5）を追加。各点検は `  <項目名>: <ok|degraded|unknown> (<詳細>)` 形式を stdout、戻り値 0=ok / 1=degraded。点検不能（`gh` 不達等）は `unknown` 表示で戻り値 0（repo 全体 degraded への昇格に算入しない / Error Handling 節）。
- 必須ラベル集合は `sh_doctor_check_labels` の `_required` 配列に明示列挙し、正本である `idd-claude-labels.sh` の `LABELS` 配列との乖離注意コメントを残した（別実行基盤で共有コードを持てないため / Req 4.4）。
- `sh_doctor_run`: env REPO/REPO_DIR/BASE_BRANCH で全 `sh_doctor_check_*` を集約し、design のレポート書式（ヘッダ `=== idd-claude doctor: ... ===` ＋各項目 ＋ `RESULT: <full|degraded>`）で出力。1 項目でも degraded なら repo 全体 degraded。`exit` ではなく `return 0`（dispatch 側で `exit $?` / Req 4.1 / 4.6 / 4.7 / NFR 3.1 / NFR 4.1）。
- `issue-watcher.sh` に `case "${1:-}" in --doctor) sh_doctor_run; exit $?;; esac` を **module source 完了後・flock 取得の前**に挿入（Decision 2）。doctor は read-only で多重起動防止の対象外。

### Finding 4（task 4.1）: README 更新

- 「オプション機能一覧」の opt-in テーブルに `SCAFFOLDING_HEALTH_HALT`（既定 `off`=可視化のみ）を追記。
- 新規節「Scaffolding Health Gate / doctor (#238)」を追加: preflight gate の挿入位置（mermaid）・既定可視化挙動と HALT opt-in 表・fail-open 仕様・`--doctor` 起動構文（REPO/REPO_DIR/BASE_BRANCH を env で渡す）・点検項目・レポート書式・必須ラベル乖離注意・ログ grep・read-only 保証・tracked repo NO-OP（false positive 0 件）・merge 後の再配置を記述。

### 検証結果

- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh` → 警告ゼロ（`.shellcheckrc` の SC2317/SC2012 accepted baseline 下。tasks.md 構造化 verify ブロックと一致）。
- `bash -n` 構文チェック → OK。
- doctor スモーク（`REPO=hitoshiichikawa/idd-claude REPO_DIR=$(pwd) BASE_BRANCH=main bash local-watcher/bin/issue-watcher.sh --doctor`）→ full レポート出力（RESULT: full）・exit 0・**`git status --porcelain` が実行前後で不変**（read-only / NFR 4.1 確認）。degraded 経路も `BASE_BRANCH=nonexistent-branch` で `RESULT: degraded` を出力し git status 不変を確認。
- スモークテスト `test-fixtures/test-scaffolding-health.sh` → 21 ケース全 PASS（full/missing/empty/zero-byte/indeterminate/空パスの検査戻り値、HALT 値正規化 6 種、missing WARN+可視シグナル、indeterminate の HALT opt-in 継続、可視シグナルの冪等抑止、read-only）。gh は stub で差し替え副作用を局所化。

### 確認事項（PR レビュワー向け）

- 可視シグナルの冪等判定は `gh issue view --json comments --jq '.comments[].body'` の出力に機械可読マーカー文字列が含まれるかを `case` で部分一致判定している。Issue 本文（body）ではなくコメント群のみを走査するため、Issue 本文に偶然同マーカーがあっても抑止されない（コメント単位の冪等で要件を満たす）。
- doctor の必須ラベル集合は中核 9 ラベル（auto-dev / claude-claimed / claude-picked-up / ready-for-review / claude-failed / needs-decisions / awaiting-design-review / needs-iteration / needs-rebase）に限定した。`idd-claude-labels.sh` には他に `skip-triage` / `staged-for-release` / `st-failed` / `awaiting-slot` / `blocked` / `hotfix` / `needs-quota-wait` があるが、これらは特定 opt-in 機能でのみ使う周辺ラベルのため doctor の「ワークフロー進行に必須な中核ラベル」点検からは除外した（design「必須ラベル集合」の方針に沿う）。過不足があれば Architect への差し戻しで調整可能。

## 受入基準カバレッジ（requirement ID → 担保テスト / 実装）

- 1.1 / 1.5 / 3.1 / 5.1 / NFR 1.1: `test-scaffolding-health.sh` の `sh_inspect_scaffolding`（full→0 / missing→1 / empty→1 / zero-byte→1 / indeterminate→2 / 空パス→2）＋ `sh_preflight_gate` full NO-OP（WARN/コメント 0）。本体 call site は `_slot_run_issue` 内 `_worktree_inject_claude` 直後に挿入。
- 1.2 / 1.3 / 1.4 / NFR 2.1: `sh_preflight_gate` missing 分岐で loud WARN ＋ `_sh_emit_visibility_signal`、`test-scaffolding-health.sh` の「missing で loud WARN を出力」「可視シグナルを呼ぶ」。全分岐で `outcome=...` ログを出すことで silent 禁止を担保。
- 2.1 / 2.2 / 2.3: `test-scaffolding-health.sh` の HALT 値正規化 6 ケース（off/未設定/空/On/true→継続、on→HALT）。
- 3.1 / 3.2 / 3.3: `test-scaffolding-health.sh` の「indeterminate + HALT=on → 0(fail-open 継続)」＋ gate indeterminate 分岐の `sh_warn` ＋ `outcome=continue` ログ。
- 4.1 / 4.2 / 4.3 / 4.4 / 4.5 / 4.6 / 4.7 / NFR 3.1 / NFR 4.1: doctor スモーク（full レポート exit 0 / git status 不変）＋ degraded 経路（base branch 解決不能 → RESULT: degraded）。各点検項目は `sh_doctor_check_*` で実装。
- 5.2: shellcheck クリーン＋ Config/REQUIRED_MODULES/call site/dispatch の追加が既存 env 名・ラベル契約・exit code・ログ書式を変えていないことをコード差分で確認。
- 5.3 / NFR 5.1: `test-scaffolding-health.sh` の「既存マーカー検出時はコメント投稿を抑止（冪等）」＋ `sh_inspect_scaffolding` の純関数性（同一状態同一戻り値）。

STATUS: complete
