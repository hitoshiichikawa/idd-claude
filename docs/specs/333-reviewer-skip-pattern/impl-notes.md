# 実装ノート — Issue #333 / REVIEWER_SKIP_PATTERN（Stage B 条件スキップ）

## 概要

opt-in env `REVIEWER_SKIP_PATTERN`（POSIX ERE、既定 空 = 無効）を導入。`run_impl_pipeline` の
Stage B（round=1）入口で `_reviewer_skip_check` を評価し、全変更ファイルがパターンに一致する
場合のみ Reviewer の claude 起動をスキップして自動 approve の review-notes.md を生成する。
不一致 / diff 空 / git 失敗 / パターン空はすべて従来経路（fail-safe）。

## 変更ファイル

1. `local-watcher/bin/issue-watcher.sh`
   - config: `REVIEWER_SKIP_PATTERN="${REVIEWER_SKIP_PATTERN:-}"`（Reviewer 設定ブロック）
   - `reviewer_skip_files_match`（純粋判定関数。`grep -Eq --` でフラグ注入防止 / #318 同方針）
   - `_reviewer_skip_check`（評価本体 + 自動 approve notes 生成 + rv_log）
   - Stage B round=1 入口の配線（スキップ時は `rs_record_stage B` を記録しない）
2. `local-watcher/test/reviewer_skip_files_match_test.sh`（新規 7 ケース）
3. `README.md` — Reviewer「環境変数」表に行を追加

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| 1.1 | config ブロック | grep |
| 1.2 / 1.3 | `_reviewer_skip_check` + round=1 入口の if 分岐 | 文面確認 |
| 1.4 | 4 条件すべて return 1（fail-safe） | テスト（関数）+ 文面確認（git 失敗 / 空） |
| 1.5 | 配線は round=1 の `run_reviewer_stage 1` 呼び出し前のみ（round=2/3 は不変） | `git diff` |
| 2.1 | heredoc の review-notes.md（marker + `RESULT: approve` 最終行） | parse_review_result 互換は既存テストの抽出規則で担保 |
| 2.2 | `rv_log "round=1 result=approve reason=skip-pattern ..."` | 文面確認 |
| 2.3 | スキップ分岐では rs_record_stage B を呼ばない | 文面確認 |
| 2.4 | notes 本文に省略の旨と人間レビュー委任を明記 | 文面確認 |
| 3.1 | 新規テスト 7 ケース | 7/7 PASS |
| 3.2 | README 行（fail-safe 条件 / idd-claude 非適用を含む） | 文面確認 |
| NFR 1 | 既定 空 → `_reviewer_skip_check` が即 return 1 → 従来コードパス | 文面確認 + スイート green |
| NFR 2 / 3 | shellcheck / スイート | 検証結果 |

## 検証結果

- 新規テスト 7/7 PASS / 既存スイート **全 PASS**（基準環境 = system bash + util-linux flock）
- `shellcheck` 新規警告ゼロ（既存 SC2329 info 6 件のみ）/ bash 5.3 `bash -n` syntax OK

## 設計上の判断

- **スキップ時に run-summary へ Stage B を記録しない**: `stages=A,C` が実行実態。`reviewer=` は
  `n/a` のままとなるが、専用ログ行（`reason=skip-pattern`）と review-notes の hidden marker で
  外形観測できる
- **review-notes.md を生成する（省略しない）**: `parse_review_result` / Stage C の commit 手順 /
  Stage Checkpoint（review-notes 存在 = Stage B 完了）との契約互換を保つため
- **round=1 入口のみ**: reject 差し戻し後（round=2/3）は是正確認が目的のため対象外
- **heredoc への env 展開**: `REVIEWER_SKIP_PATTERN` は operator 設定（cron / launchd）であり
  未信頼入力ではない（config コメントに明記）。grep には `--` を適用（#318 と同方針）

## 確認事項（PR レビュワー向け）

- スキップは「独立レビューの省略」であり品質ゲートの弱化を伴う。opt-in 既定無効・全ファイル
  一致条件・fail-safe の 3 段で限定し、README で idd-claude 自身への適用を禁止した
- `origin/<BASE_BRANCH>..HEAD` の比較は reviewer プロンプトの diff 取得（`<BASE_BRANCH>..HEAD`）
  より厳密（worktree は origin 起点 reset のため通常等価）
