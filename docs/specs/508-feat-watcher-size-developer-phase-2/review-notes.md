# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-07-22T23:23:34Z -->

## Reviewed Scope

- Branch: claude/issue-508-impl-feat-watcher-size-developer-phase-2
- HEAD commit: 4a9aec4775b808ba4373e5a8f386c8df65bc1f13
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/model-router.sh` / `local-watcher/bin/modules/slot-worker.sh` /
  `local-watcher/bin/watcher-config.sh` / `local-watcher/test/model_router_test.sh` / `README.md` /
  spec 配下 2 ファイル（計 7 ファイル / +1177 -21）
- 本 Issue は design-less impl（`design.md` / `tasks.md` 不在）のため、`_Boundary:_` アノテーションは
  存在しない。boundary 判定は `requirements.md` の Out of Scope 節を境界の正本として実施した。

## Verified Requirements

- 1.1 — `mr_resolve_dev_model` の `small` 分岐が `DEV_MODEL_SMALL` 非空時に当該値を返す（model-router.sh:309-314）/ テスト P2-1
- 1.2 — 同 `medium` 分岐（model-router.sh:316-320）/ テスト P2-1
- 1.3 — `large` 分岐は no-op で末尾の `DEV_MODEL` 合流点へ落ちる（model-router.sh:322-323, 332）/ テスト P2-1・P2-3
- 1.4 — `*)` 分岐で許可値以外・空・引数省略をすべて `DEV_MODEL` へ fail-safe（model-router.sh:325-327）/ テスト P2-2（`huge` / `SMALL` / `Small` / `small medium` / `--model` / 空 / 引数省略）
- 1.5 — size 別設定が空／unset のとき条件分岐を抜けて `DEV_MODEL` へ合流 / テスト P2-3（空文字・unset 双方）
- 1.6 — 許可値リストを持たず `printf '%s\n'` でそのまま返す / テスト P2-5（`not-a-real-model-id-xyz` がそのまま返る）
- 1.7 — 外部コマンド・ログ・状態変更なしの純粋関数 / テスト P2-7（gh 0 回 / ログ 0 行 / `DEV_MODEL`・`DEV_MODEL_SMALL` 不変）
- 1.8 — 決定性 / テスト P2-6（同一入力 → 同一出力）、P2-8（gate 値に依存しない）
- 2.1 — `DEV_MODEL_SMALL="${DEV_MODEL_SMALL:-}"` / `DEV_MODEL_MEDIUM="${DEV_MODEL_MEDIUM:-}"`（watcher-config.sh:1240-1241）/ テスト P4-1
- 2.2 — 既定値にモデル ID を埋め込まない / テスト P4-2（`claude-` 出現 0 件）
- 2.3 — gate 有効かつ size 別モデル未設定なら `DEV_MODEL`（二重 opt-in）/ テスト P3-3
- 2.4 — `DEV_MODEL="${DEV_MODEL:-claude-opus-4-8}"` 行は不変（diff で追加のみ）/ テスト P4-4
- 2.5 — 追加設定値は 2 個のみ / テスト P4-3（`^DEV_MODEL_[A-Z]+=` が 2 件・`DEV_MODEL_LARGE` 0 件）
- 2.6 — 既存モデル系 env の宣言行に diff なし（`git diff` は watcher-config.sh に +20 行の追加のみ）/ テスト P4-4
- 3.1 — `_slot_run_issue` 冒頭で `LABELS`（起動時スナップショット）を入力に `_slot_apply_dev_model_routing` を呼び `DEV_MODEL` を確定（slot-worker.sh:294-313）/ テスト P3-2・P4-7
- 3.2 — `mr_extract_size_label` の `case` 完全一致（`size:small|size:medium|size:large`）/ テスト P1-1（無関係ラベル混在含む）
- 3.3 — `size:` prefix 0 件 → rc=1 → `DEV_MODEL` / テスト P1-2・P3-4
- 3.4 — `size:` prefix 2 件以上 → rc=2 → `DEV_MODEL` / テスト P1-3・P3-5（異値併存・同値重複・有効値+不正値）
- 3.5 — 1 件だが厳密一致失敗 → rc=3 → `DEV_MODEL` / テスト P1-4（8 パターン）・P3-6
- 3.6 — グローバル `DEV_MODEL` 再代入を worktree 初期化前に 1 回行い、以降の design セッション（slot-worker.sh:842）／実装 Stage 群（impl-pipeline.sh:319, 439, 597, 719）／per-task ループ（per-task-loop-exec.sh:124, 196）がいずれも同一の `$DEV_MODEL` を参照する（grep で確認）/ テスト P4-7・P3-8
- 3.7 — `_slot_run_issue` は `( _slot_run_issue "$slot" "$issue" ) &`（issue-watcher.sh:855）でサブシェル fork され再代入が親へ伝播しない / テスト P3-8（親の `DEV_MODEL` 不変）
- 3.8 — 適用ヘルパー／model-router.sh とも `TRIAGE_MODEL` / `REVIEWER_MODEL` / `PJM_MODEL` を参照しない / テスト P4-6
- 3.9 — `PR_ITERATION_DEV_MODEL` / `FAILED_RECOVERY_DEV_MODEL` は config ロード時（親プロセス）に確定し slot 内再代入の影響を受けない / テスト P4-6
- 4.1 — call site は 1 箇所のみ / テスト P4-7（`grep -c` = 1）
- 4.2 — call site が Triage 消費部より前のため、同一 slot で Triage が付与したラベルは使われない / テスト P4-8・README の「⚠️ 初回 Triage 経路では効きません」
- 4.3 — Triage 後の再解決コードなし / テスト P4-8（call site 行番号 < `mr_persist_size_label` 呼び出し行番号）
- 4.4 / 4.5 / 4.6 — MODE 分岐（impl-resume / skip-triage / 初回）より前の共通パスに差し込まれているため 3 経路とも同一コードで解決される（slot-worker.sh の call site 位置で確認）/ テスト P3-2
- 5.1 — gate は `mr_is_enabled`（= `MODEL_ROUTING_ENABLED`）のみ / テスト P4-5（独自 gate 変数参照 0 件）
- 5.2 — `mr_is_enabled || return 0` で読み取りも解決も行わない（slot-worker.sh:216）/ テスト P3-1
- 5.3 — gate 無効時ログ 0 行 / テスト P3-1（9 パターン: 空 / `false` / `off` / `True` / `TRUE` / `1` / `yes` / `ture` / unset）
- 5.4 — `[ "${MODEL_ROUTING_ENABLED:-false}" = "true" ]` の厳密一致（model-router.sh:66-68）/ テスト P3-1
- 5.5 — ラベル遷移・exit code・ログ出力先・cron 文字列への変更は diff 上に存在しない（追加は新関数と新 env 2 個のみ）/ テスト P4-9
- 5.6 — 解決結果が空なら再代入せず WARN 1 行 + rc=0（slot-worker.sh:225-229）/ テスト P3-7
- 6.1 — `mr_log "issue=#... size=... dev_model=..."` の 3 項目 1 行（slot-worker.sh:254-256）/ テスト P3-2
- 6.2 — fallback 時は `fallback=DEV_MODEL（理由: ...）` を付与 / テスト P3-3・P3-4・P3-5・P3-6
- 6.3 — `mr_log` は stdout へ出力し、call site が `exec > >(tee -a "$SLOT_LOG") 2>&1` の直後にあるため cron ログ / slot ログ双方に残る（既存 processor と同一経路）
- 6.4 — 全分岐でログ 1 行（正常 / fallback / WARN）/ テスト P3-2・P3-3・P3-4・P3-7 の「ログは 1 行」アサーション
- 7.1 — README「ステージ別モデル」表に `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM`（既定「（空）」）を追加
- 7.2 — README Phase 2 節「モデルが変わるには 2 つの条件が両方必要です（二重 opt-in）」+ オプション機能一覧の必須欄
- 7.3 — README「適用タイミングと既知の制約（重要）」節（1 回解決 + ⚠️ 初回 Triage 経路 + 効く 3 経路）
- 7.4 — README「適用範囲と対象外」節（Triage / Reviewer / PjM / slot 外プロセッサを明記）
- 7.5 — README「解決結果の一覧」表（9 行 / small・medium・large・なし・複数・不正値・gate OFF）
- 7.6 — README 更新は実装と同一 PR（同一ブランチ commit 70b7b3e）
- 8.1 — `shellcheck` を reviewer 側で再実行し警告ゼロを確認（model-router.sh / slot-worker.sh / watcher-config.sh / model_router_test.sh）
- 8.2 — `bash -n` を上記 4 ファイルで再実行し通過を確認
- 8.3 — 近接テストは既存命名規約どおり `local-watcher/test/model_router_test.sh` に追加（+416 行）
- 8.4 — Unit P2（3 値 × 設定あり／なし・許可値以外・空文字）が該当ケースを網羅
- 8.5 — Integration P3-1 / P3-4 / P3-5 / P3-6（gate 無効 / ラベルなし / 複数 / 不正値）で `DEV_MODEL` 適用を検証
- 8.6 — P3-1 が `wc -l` でログ 0 行を検証（gate 9 表現）
- 8.7 — P3-8 がサブシェル境界（子で適用・親で不変）を検証
- NFR 1.1 / 1.2 / 1.3 — gate OFF 時の完全 no-op（P3-1）、未設定既定での従来挙動（P3-1 unset ケース）、他 Stage モデル契約不変（P4-6）
- NFR 2.1 / 2.2 / 2.3 / 2.4 — gate OFF で外部コマンド 0 回（P3-1）、gate ON でも gh 0 回（P3-2 / P3-6）、LLM 追加起動なし（diff 上に claude 呼び出し追加なし）、1 slot 1 回（P4-7）
- NFR 3.1 / 3.2 / 3.3 / 3.4 — ラベル名は bash `case` の完全一致のみで検証し外部コマンドへ渡さない（`grep` / `sed` 不使用）、ログには固定トークンのみ（P3-6 の生値非出力アサーション）、モデル ID ハードコードなし（P4-2）

### reviewer 側で再実行した検証

| コマンド | 結果 |
|---|---|
| `bash -n`（変更 4 スクリプト） | OK |
| `shellcheck`（変更 4 スクリプト） | 警告ゼロ |
| `bash local-watcher/test/model_router_test.sh` | PASS 309 / FAIL 0 |
| slot-worker.sh 参照テスト 4 本 + watcher-config.sh 参照テスト 3 本 | すべて FAIL 0（回帰なし） |

## Findings

なし

## Summary

`requirements.md` の Requirement 1〜8 および NFR 1〜3 の全 numeric ID について、実装またはテストの
対応を確認できた。追加分は純粋関数 2 本（model-router.sh）+ slot 適用ヘルパー 1 本（slot-worker.sh）
+ 既定空の env 2 個 + 近接テスト 163 件 + README 節で、gate OFF 時は完全 no-op（P3-1 で 9 表現を検証）。
Out of Scope（既存 `DEV_MODEL` 個別 call site の書き換え / `DEV_MODEL_LARGE` 追加 / slot 外プロセッサ
への波及 / Actions workflow）に触れる変更はなく、`local-watcher/` は `repo-template/` にミラーされない
ため同期ドリフトも発生しない。reviewer 側で shellcheck / `bash -n` / 近接テスト（309 PASS 0 FAIL）と
周辺テストの回帰なしを再確認した。

なお impl-notes.md「確認事項 1」の「初回 Triage 経路では routing が効かない」は、確定済み
requirements.md（Req 4.2 / Note / Out of Scope）が意図された既知の制約として明示採用したもので、
本 impl PR は現行確定 spec を正しく満たしている。仕様を強化する（Triage 直後に再解決する）べきか
どうかは設計レベルの指摘であり、本 impl PR の reject 理由には含めない（別 Issue / 設計 iteration へ
還流すべき人間判断事項）。

RESULT: approve
