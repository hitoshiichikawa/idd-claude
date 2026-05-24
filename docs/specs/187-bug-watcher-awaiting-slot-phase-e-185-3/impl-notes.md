# 実装ノート（Issue #187）

## 概要

Phase E Path Overlap Checker の `po_apply_awaiting_slot`（`local-watcher/bin/modules/promote-pipeline.sh`）が、
awaiting-slot ラベル付与に失敗すると early `return 1` してしまい、後続の sticky comment 投稿コードに到達しない
バグを修正した。これにより、ラベル付与に失敗したケースでも「なぜ Issue が止まっているか」を Issue 上の
コメントから読み取れるようにし、dispatch 見送り理由の可視性を回復した。

実害（誤 dispatch）は発生しないため、スコープは可視性の回復に限定した（要件 Out of Scope に準拠）。

## Feature Flag Protocol 採否確認

`CLAUDE.md` を確認したが `## Feature Flag Protocol` 節は存在しない。よって opt-out 解釈となり、
通常フロー（単一実装パス）で実装した（`.claude/rules/feature-flag.md` は読み込まない）。

## 修正した関数と before/after の構造

### `po_apply_awaiting_slot`（promote-pipeline.sh 430-507 付近）

**before:**

```bash
# ラベル付与（冪等。既付与でも error にならない）
if ! gh issue edit "$issue_number" --repo "$REPO" \
    --add-label "$LABEL_AWAITING_SLOT" >/dev/null 2>&1; then
  return 1          # ← ここで早期終了し、以降の sticky comment 投稿に到達しない
fi
po_log "awaiting-slot added candidate=#${issue_number}"
# （以降に sticky comment 組み立て・投稿/更新コード）
```

**after:**

```bash
# ラベル付与（冪等。既付与でも error にならない）。
# #187: ラベル付与に失敗しても early return せず、警告ログを残した上で sticky comment
# 投稿へ処理を継続する。
if gh issue edit "$issue_number" --repo "$REPO" \
    --add-label "$LABEL_AWAITING_SLOT" >/dev/null 2>&1; then
  po_log "awaiting-slot added candidate=#${issue_number}"
else
  po_warn "issue=#${issue_number} awaiting-slot ラベル付与に失敗（見送り理由コメントの投稿は継続）"
fi
# （以降の sticky comment 組み立て・投稿/更新コードは無変更で必ず到達する）
```

変更は冒頭のラベル付与ブロックのみ。sticky comment 本文フォーマット・marker
（`<!-- idd-claude:awaiting-slot:v1 -->`）・冪等な PATCH/create ロジックは一切変更していない
（要件 1.4 / NFR 2.1 / Out of Scope）。

### 戻り値の変化と呼び出し側への影響

- before: ラベル付与失敗時 `return 1`、それ以外は `return 0`
- after: ラベル付与の成否に関わらず、本文組み立て後の投稿/更新を経て `return 0`（コメント取得失敗の
  best-effort 経路も従来どおり `return 0`）

呼び出し側 `po_check_dispatch_gate`（531-595）は overlap 検出時に
`if ! po_apply_awaiting_slot ...; then po_warn ...; fi` の **後** に**無条件で `return 1`（dispatch skip）** する
構造（584 行）。dispatch skip は `po_apply_awaiting_slot` の戻り値に依存していないため、戻り値が
常に 0 に変わっても dispatch skip の維持に影響しない（NFR 1.2）。`if ! ... then po_warn` 分岐は
ラベル付与失敗時に呼ばれなくなる（関数内部で WARN するため）が、overlap 検出ログ（573/577 行）と
dispatch skip（584 行）は不変。

## 追加したテストファイルと検証 AC の対応

追加ファイル: `local-watcher/test/po_apply_awaiting_slot_test.sh`
（既存 `pi_max_rounds_kind_test.sh` の per-test `*_SH` source + `awk` extract_function イディオムを踏襲。
`gh` / `po_log` / `po_warn` を stub し、呼び出し有無・引数・戻り値を観測）

| AC | 検証ケース |
|---|---|
| Req 1.1 / 1.2（ラベル付与成否に依存せず sticky comment 投稿/更新を試行） | Case A（ラベル付与失敗 → 新規 comment 投稿 1 回）、Case B（ラベル付与失敗 + 既存 marker → PATCH 1 回）、Case E（ラベル付与失敗 + コメント取得失敗 → best-effort 新規投稿 1 回） |
| Req 1.4 / NFR 2.1（既存 marker があれば追加投稿せず PATCH 更新） | Case B（label fail）、Case D（label success）双方で「新規 comment 0 回 / PATCH 1 回」、PATCH 対象 comment id (555111) を検証 |
| Req 3.1（ラベル付与失敗時に候補 Issue 番号を含む WARN ログ） | Case A（#42 を含む WARN）、Case E（#99 を含む WARN） |
| Req 2.3（ラベル/コメント投稿失敗でも当該サイクルを異常終了させない） | Case E（ラベル付与失敗 + コメント取得失敗でも戻り値 0） |
| Req 2.4 / NFR 1.2（戻り値の意味が dispatch skip 維持に影響しない） | Case A / B（label fail でも戻り値 0） |
| NFR 2.1（ラベル付与成功時の従来挙動が回帰しない） | Case C（label success → 新規 comment 1 回 / WARN 無し / 付与成功 LOG 有り）、Case D（label success + 既存 marker → PATCH 冪等更新） |

合計 19 アサーション、全 PASS。

## 実行したスモークテスト結果

### Red → Green 観測

- `git stash`（修正前コード）で新規テストを実行 → **9 FAIL / 10 PASS**（label-failure 系の AC が全て失敗、
  label-success 系の回帰テストは pass）。バグを確実に捕捉していることを確認。
- `git stash pop`（修正後コード）で再実行 → **19 PASS / 0 FAIL**。

### shellcheck

```
shellcheck local-watcher/bin/modules/promote-pipeline.sh local-watcher/test/po_apply_awaiting_slot_test.sh
=> exit 0（警告ゼロ）
```

修正本体は新たな警告を増やしていない。新規テストは SC2034（遅延束縛グローバル）・SC2317（間接呼び出し
stub）を既存テストと同じ inline `# shellcheck disable` で抑止し clean。

### 既存テスト suite 全件（local-watcher/test/*_test.sh）

全 14 suite を実行し全て PASS（新規 po_apply_awaiting_slot_test.sh 含む）:

| test | result |
|---|---|
| module_loader_missing_test.sh | PASS (7) |
| normalize_slug_test.sh | PASS (11) |
| parse_review_result_test.sh | PASS (19) |
| pi_detect_quota_soft_fail_test.sh | PASS (13) |
| pi_max_rounds_kind_test.sh | PASS (24) |
| po_apply_awaiting_slot_test.sh（新規） | PASS (19) |
| qa_detect_rate_limit_test.sh | PASS (10) |
| qa_run_claude_stage_test.sh | PASS (23) |
| repo_prefix_log_test.sh | PASS (36) |
| slug_match_guard_test.sh | PASS (13) |
| stagec_pr_verify_fallback_test.sh | PASS (35) |
| stagec_pr_verify_retry_test.sh | PASS (42) |
| stagec_pr_verify_test.sh | PASS (8) |
| verify_pushed_or_retry_test.sh | PASS (17) |

## 後方互換性の確認

- **戻り値**: `po_apply_awaiting_slot` は修正後も `0` を返す経路のみ（致命 return 1 を除去）。呼び出し側の
  dispatch skip は `po_apply_awaiting_slot` の戻り値ではなく 584 行の無条件 `return 1` で決まるため不変
  （NFR 1.2）。
- **dispatch skip**: overlap 検出時の `return 1`（po_check_dispatch_gate 584）は無変更。overlap 判定・
  in-flight 列挙・clear ロジックも無変更（要件 Out of Scope 準拠）。
- **ラベル遷移契約**: `LABEL_AWAITING_SLOT` の付与/除去ラベル名・marker・本文フォーマットは無変更
  （要件 2.4）。
- **env var 名・ログ出力先**: `po_log`（stdout）/ `po_warn`（stderr）の出力先・既存 env var 名は無変更
  （要件 2.4 / NFR 1.1）。新たに出力する WARN は path-overlap prefix を共有する `po_warn` 経由。
- **opt-in gate**: `PATH_OVERLAP_CHECK` の gate（po_check_dispatch_gate 536）は無変更。`true` 以外では
  本修正経路に到達しないため、無効時は導入前と完全同一（NFR 1.1）。
- **冪等性**: 既存 marker 検索 → PATCH/create ロジックは無変更のため、連続サイクルでも sticky comment は
  1 件に保たれる（NFR 2.1。Case B / D で検証）。

## requirements / design で曖昧だった点とその解釈

- Req 2.3「次サイクルでの再評価に委ねる」: 本修正では関数が異常終了（return 1）しなくなることで充足。
  ラベル付与失敗の事実は WARN ログに残し、次サイクルで `po_check_dispatch_gate` が再度 overlap 判定 →
  未付与なら再度 `po_apply_awaiting_slot` を呼ぶ既存フローに委ねる（追加のリトライ機構は実装しない）。
- Out of Scope の「受入観点 (2) の軽量フォールバック（欠落ラベル検出 → WARN / 自動ラベル作成）」は
  別 Issue 扱いのため本修正では実装していない（過剰修正の回避）。

## 確認事項（Reviewer 判断ポイント）

- なし。要件 / design.md（本 Issue は design.md / tasks.md なしのバグ修正）と矛盾は検出されなかった。
  修正は要件で指定された最小スコープ（`po_apply_awaiting_slot` 冒頭のラベル付与ブロックのみ）に限定し、
  sticky comment フォーマット・overlap 判定・呼び出し側 dispatch skip は不変であることをテストで担保した。

STATUS: complete
