# Implementation Plan

> 各タスクは 1 commit 単位で独立完了可能な粒度。`(P)` 付きタスクは並列実行可能（境界を `_Boundary:_` で明示）。
> 設計参照: `docs/specs/125-feat-watcher-stage-a-tasks-md-verify-bui/design.md`
> 既存 watcher との後方互換性（NFR 1.1〜1.3）を維持すること。`STAGE_A_VERIFY_ENABLED=false` 明示時の挙動は本機能導入前と完全一致でなければならない。

- [x] 1. Config ブロック: 新 env 3 種の追加
- [x] 1.1 `local-watcher/bin/issue-watcher.sh` の Config ブロックに `STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` / `STAGE_A_VERIFY_COMMAND` を追加
  - 既存 `STAGE_CHECKPOINT_ENABLED` ブロック（L179-L185 周辺）の直後に新節「─── Stage A Verify 設定 (#125) ───」を挿入
  - `STAGE_A_VERIFY_ENABLED="${STAGE_A_VERIFY_ENABLED:-true}"` / `STAGE_A_VERIFY_TIMEOUT="${STAGE_A_VERIFY_TIMEOUT:-600}"` / `STAGE_A_VERIFY_COMMAND="${STAGE_A_VERIFY_COMMAND:-}"`
  - L251-L267 の `_idd_flag` ループ（#112 デフォルト有効化フラグの正規化）には **加えない**（本機能は `=false` 厳密一致のみ opt-out とし、他 8 種と同形ではあるが「未設定 vs 空 vs typo を opt-out として扱う」の判別が値検証ロジック上独立する。意図的に既存ループの正規化対象外とする）
  - 既存 env 名 / 既定値を変更しないこと（Req 4.5 / NFR 1.1）
  - `shellcheck` を流して警告ゼロを維持
  - _Requirements: 4.1, 4.2, 4.3, 4.5, NFR 1.1, NFR 3.3_

- [x] 2. Stage A Verify Module のヘルパ関数群を実装
- [x] 2.1 `sav_log` / `sav_warn` / `sav_error` ロガーを追加 (P)
  - `Stage Checkpoint Module` ブロック（L2985-L3014 周辺）の直前 or 直後を推奨。既存 `sc_log` と同じファイル位置に並置
  - 行頭 prefix は `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify:` 固定（Issue #119 規約 / NFR 4.1 / NFR 4.2）
  - warn / error は stderr へ
  - _Requirements: 5.1, 5.2, NFR 4.1, NFR 4.2_
  - _Boundary: issue-watcher.sh (logger 関数群)_

- [x] 2.2 `stage_a_verify_extract_command` 関数を実装 (P)
  - design.md「Components and Interfaces / stage_a_verify_extract_command」の擬似コードに従う
  - 関数内 readonly 配列 `_SAV_KEYWORDS` に design.md で確定したキーワード集合を列挙
  - awk 1 パスで末尾走査し、末尾に最も近い 1 行を stdout に出す（O(N), Req 1.1 / 1.2 / NFR 3.1）
  - 抽出した行から markdown bullet 装飾（`- `、行頭空白、行末空白）を strip する
  - tasks.md 不在時 / 一致なし時は exit code 1
  - _Requirements: 1.1, 1.2, 1.5, NFR 2.1, NFR 3.1_
  - _Boundary: issue-watcher.sh (stage_a_verify_extract_command)_

- [x] 2.3 `stage_a_verify_resolve_command` 関数を実装 (P)
  - `STAGE_A_VERIFY_COMMAND` 非空時は最優先で採用（Req 4.4 / NFR 2.2）
  - 空ならば `stage_a_verify_extract_command` を呼ぶ
  - 解決失敗時は exit code 1
  - _Requirements: 4.4, NFR 2.2_
  - _Boundary: issue-watcher.sh (stage_a_verify_resolve_command)_
  - _Depends: 2.2_

- [x] 2.4 round counter helpers (`_round_path` / `_read_round` / `_bump_round` / `_reset_round`) を実装 (P)
  - sidecar path は `$REPO_DIR/$SPEC_DIR_REL/.stage-a-verify-round`
  - 不在は round=0、書き込み失敗時は `sav_error` で警告（呼び出し元は差し戻し挙動を強制）
  - 書き込みは `printf '%d\n' "$N" > "$path"`
  - _Requirements: 3.1, 3.2, 3.3_
  - _Boundary: issue-watcher.sh (round counter sidecar)_

- [x] 3. `stage_a_verify_run` 統合ランナーを実装
  - design.md「stage_a_verify_run / Internal Flow」の擬似コードに従う
  - Gate 1（DISABLED）: `STAGE_A_VERIFY_ENABLED=false` 明示時 → `sav_log "DISABLED reason=env-opt-out"` + return 0（Req 4.1 / 5.4）
  - Gate 2（SKIPPED）: resolve_command が失敗時 → `sav_log "SKIPPED reason=no-verify-task-in-tasks-md"` + return 0（Req 1.4 / 5.3）
  - Execute: `(cd "$REPO_DIR" && timeout --kill-after=10 "$STAGE_A_VERIFY_TIMEOUT" bash -c "$cmd") >> "$LOG" 2>&1`（Req 1.3 / 2.1 / 2.5 / NFR 3.2 / NFR 5.1 / NFR 5.2）
  - 結果分岐: exit 0 → SUCCESS + round reset + return 0（Req 2.2）、exit 124 → TIMEOUT + round bump + return 1 or 2（Req 2.4）、その他 → FAILED + round bump + return 1 or 2（Req 2.3）
  - `_sav_handle_failure` 補助関数で round=1 差し戻し / round=2 escalate を分岐（Req 3.1 / 3.2）
  - round=1 時: gh issue comment で差し戻し説明を投稿（claude-failed は付与しない / `needs-iteration` も Issue 側には付けない既存契約を維持）
  - round=2 時: `mark_issue_failed "stageA-verify" "$body"` を呼んで claude-failed 化 + round counter を reset
  - 全分岐で `[$REPO] stage-a-verify:` ログを 1 行以上必ず出力（NFR 4.1）
  - _Requirements: 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 5.1, 5.3, 5.4, 5.5, NFR 3.2, NFR 4.1, NFR 5.1, NFR 5.2_
  - _Boundary: issue-watcher.sh (stage_a_verify_run / _sav_handle_failure)_
  - _Depends: 1.1, 2.1, 2.3, 2.4_

- [ ] 4. `run_impl_pipeline` への挿入
  - design.md「run_impl_pipeline 挿入ブロック」の擬似コードに従い、Stage A 実行ブロックの直後・Stage B 実行ブロックの直前（現行 L4225 周辺、`case "$START_STAGE" in A) … B|C) … esac` の直後）に挿入する
  - Stage A skipped path（START_STAGE=B|C）でも本ブロックを通すこと（Stage Checkpoint resume との協調、design.md「stage-a-verify と Stage Checkpoint の協調」参照）
  - `stage_a_verify_run` の戻り値 0/1/2 を `run_impl_pipeline` の戻り値 0/1 にマップし、既存 exit code 契約（NFR 1.3）を維持
  - 既存 `echo "✅ Stage A 完了"` / `echo "⏭️  Stage A スキップ"` / `echo "✅ Reviewer round=1 approve"` 等の文言は変更しないこと
  - `run_impl_pipeline` の関数 header コメント（L4111-L4141）に「stage-a-verify gate (#125)」の言及を 1 ブロック追記する
  - _Requirements: 2.2, 2.3, 4.1, 4.5, 6.1, 6.2, 6.3, NFR 1.1, NFR 1.3_
  - _Depends: 3_

- [ ] 5. fixture テストの追加（抽出関数の回帰検出）
- [ ] 5.1 `tests/local-watcher/stage-a-verify/fixtures/` を新設し、design.md「Testing Strategy / Unit-level」の 12 fixture を配置 (P)
  - `tasks-gradlew.md` / `tasks-npm.md` / `tasks-cargo.md` / `tasks-go.md` / `tasks-pytest.md` / `tasks-make.md` / `tasks-bundle.md` / `tasks-shellcheck.md` / `tasks-no-verify.md` / `tasks-deferrable.md` / `tasks-mixed.md` / `tasks-empty.md`
  - 各 fixture は実在 tasks.md と同じ書式（markdown bullet + アノテーション）を模す
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, NFR 6.1_
  - _Boundary: tests/local-watcher/stage-a-verify/fixtures_

- [ ] 5.2 `tests/local-watcher/stage-a-verify/extract-driver.sh` を実装 (P)
  - 各 fixture を一時 `$REPO_DIR/$SPEC_DIR_REL/tasks.md` として配置し、`stage_a_verify_extract_command` を source して呼ぶ
  - stdout と期待文字列を diff、全件 pass で exit 0 / 不一致あれば該当 fixture 名 + diff を出して exit 1
  - 期待値は fixture 隣の `.expected` ファイル or driver 内の lookup table のいずれか（実装判断、driver 内 lookup を推奨）
  - shellcheck クリーン
  - _Requirements: 1.1, 1.2, 1.5, NFR 6.1_
  - _Boundary: tests/local-watcher/stage-a-verify/extract-driver.sh_
  - _Depends: 2.2, 5.1_

- [ ]* 5.3 smoke test driver `tests/local-watcher/stage-a-verify/smoke.sh` を追加（deferrable）
  - DISABLED / SUCCESS / FAILED round=1 / FAILED round=2 / TIMEOUT / SKIPPED の 6 シナリオを fixture + env 切替で再現
  - 実際の `gh issue comment` / `mark_issue_failed` は dry run（モック）でログ出力のみに留める
  - `STAGE_A_VERIFY_COMMAND="exit 1"` 等で round=1/2 path を確実に再現
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 4.1, 5.5, NFR 6.2_
  - _Boundary: tests/local-watcher/stage-a-verify/smoke.sh_

- [ ] 6. README / ドキュメント整備
- [ ] 6.1 README.md「オプション機能（標準有効 / 常時有効）一覧」表に `Stage A Verify Gate` 行を追加し、専用節を新設 (P)
  - 既存「デフォルト有効（無効化する場合のみ `=false` 明示）」表（L1020-L1030）の末尾に行を 1 行追加: `**Stage A Verify Gate** (tasks.md 末尾 verify タスクの独立再実行) | STAGE_A_VERIFY_ENABLED | true | [Stage A Verify Gate (#125)](#stage-a-verify-gate-125) | #125`
  - 既存「## Stage Checkpoint (#68)」節（L2461 付近）の直後に「## Stage A Verify Gate (#125)」節を新設
  - 専用節に含める項目: 機能概要 / 状態遷移図（Mermaid）/ env 3 種一覧表 / cron 例（opt-out / escape hatch / timeout 延長）/ 影響範囲と既存挙動との互換性 / 失敗・異常系 / Migration Note / merge 後の再配置注意
  - migration note には「初回配置後に `cron.log` で `stage-a-verify:` 行を観測すること」「未対応言語は `STAGE_A_VERIFY_COMMAND` で escape」「`STAGE_A_VERIFY_ENABLED=false` 明示で完全 opt-out」を明記
  - L1004-L1016 の `Migration Note (#112)` の対象 8 種リストには **加えない**（本機能は #125 独立の機能であり、#112 の defaulting 反転とは別系統）
  - _Requirements: 4.1, 4.2, 4.3, 4.4, NFR 1.1, NFR 1.2, NFR 1.3_
  - _Boundary: README.md_

- [ ]* 6.2 root `CLAUDE.md` の「禁止事項」「エージェント連携ルール」節に stage-a-verify との整合を 1 行追記（deferrable）
  - 「Developer 責務は変更しない（tasks.md 実装と commit のみ）」（Req 6.3）を補強する 1 行
  - 「Reviewer の判定カテゴリは AC 未カバー / missing test / boundary 逸脱のみ。build pass は stage-a-verify が watcher 段で独立に検証する」（Req 6.1）を補強する 1 行
  - これらは既存記述で十分明確なら省略可。**実装段階で判断**してよい
  - _Requirements: 6.1, 6.3_
  - _Boundary: root CLAUDE.md_

- [ ] 7. 最終検証（手動スモークテスト + static analysis）
  - **Static analysis**:
    - `shellcheck local-watcher/bin/issue-watcher.sh .github/scripts/*.sh install.sh setup.sh tests/local-watcher/stage-a-verify/extract-driver.sh` — 警告ゼロ
    - `actionlint .github/workflows/*.yml` — クリーン
  - **fixture テスト**: `bash tests/local-watcher/stage-a-verify/extract-driver.sh` で全件 pass
  - **手動スモークテスト（cron-like 最小 PATH で実施）**:
    1. dry run: `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を対象なし状態で流し、エラーなく終了することを確認
    2. opt-out 検証: `STAGE_A_VERIFY_ENABLED=false REPO=... REPO_DIR=... $HOME/bin/issue-watcher.sh` で cron.log に `stage-a-verify:` 行が 1 行も出ないこと（NFR 1.1）
    3. timeout 動作確認: 一時 spec dir に `tasks.md` を置き、`STAGE_A_VERIFY_COMMAND="sleep 1000" STAGE_A_VERIFY_TIMEOUT=2` で起動し `TIMEOUT` ログが出ること（NFR 3.2 / NFR 5.2）
    4. round counter 動作確認: 失敗するコマンドで 2 回連続起動し、1 回目で sidecar に "1" / Issue コメント、2 回目で `claude-failed` ラベル付与
  - 結果を `impl-notes.md` に記録（CLAUDE.md「テスト・検証」節の方針に従う）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 4.1, 4.2, 4.3, 4.4, 4.5, 5.1, 5.2, 5.3, 5.4, 5.5, NFR 1.1, NFR 1.2, NFR 1.3, NFR 3.2, NFR 4.1, NFR 4.2, NFR 5.1, NFR 5.2, NFR 6.2_
  - _Depends: 1.1, 2.1, 2.2, 2.3, 2.4, 3, 4, 5.2, 6.1_
