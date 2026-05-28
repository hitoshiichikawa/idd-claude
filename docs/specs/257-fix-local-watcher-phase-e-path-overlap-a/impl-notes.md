# Implementation Notes — #257 fix(local-watcher): Phase E Path Overlap awaiting-slot sticky comment PATCH 経路の修復

## 変更したファイル

- `local-watcher/bin/modules/promote-pipeline.sh`
  - `po_check_dispatch_gate` 関数内 (L863-867) の `if [ -z "$has_awaiting" ]` ガードを除去
  - `awaiting-slot` ラベル付与状態に関わらず毎サイクル `po_apply_awaiting_slot` を呼び出す
  - 警告メッセージを「ラベル付与 / コメント投稿に失敗」から「ラベル付与 / コメント更新に失敗」へ実態に合わせて微調整
  - 修正コメントとして `#257 Req 1.1 / 1.2 / 1.3 / 2.2 / NFR 3.1` のトレーサビリティ参照を追加
- `docs/specs/257-fix-local-watcher-phase-e-path-overlap-a/test-fixtures/test-awaiting-slot-update.sh`（新規）
  - 31 ケースの回帰テスト。AC を満たすことを `gh` スタブ + 依存関数 mock で観測する
- `docs/specs/257-fix-local-watcher-phase-e-path-overlap-a/impl-notes.md`（本ファイル）

## 差分概要

`po_check_dispatch_gate` の最小差分修正:

```diff
-    if [ -z "$has_awaiting" ]; then
-      if ! po_apply_awaiting_slot "$candidate" "$overlap" "$overlap_holders_map"; then
-        po_warn "issue=#${candidate} awaiting-slot 付与 / コメント投稿に失敗（次サイクルで再評価）"
-      fi
+    if ! po_apply_awaiting_slot "$candidate" "$overlap" "$overlap_holders_map"; then
+      po_warn "issue=#${candidate} awaiting-slot 付与 / コメント更新に失敗（次サイクルで再評価）"
     fi
```

`po_apply_awaiting_slot` 自体は本修正前から既に「マーカー (`<!-- idd-claude:awaiting-slot:v1 -->`)
付きコメントを `gh issue view --json comments` で検索 → 存在すれば `gh api -X PATCH`、無ければ
`gh issue comment` で新規 create」のロジックを `local-watcher/bin/modules/promote-pipeline.sh:577-600`
に持っており、関数本体には手を入れていない。バグは「`po_check_dispatch_gate` がガードでこの関数
呼び出し自体を skip していた」点だけにある。

`has_awaiting` 変数は overlap 空時の自然解消経路（L872, `if [ -n "$has_awaiting" ]; then
po_clear_awaiting_slot ...`）で引き続き使われるため、抽出処理 (L843-846) と変数自体は残置。

## AC ごとのカバー方針

### Requirement 1: Awaiting-slot sticky comment の最新化

| AC | 担保方針 | テストケース |
|---|---|---|
| 1.1 | `po_check_dispatch_gate` がラベル付与状態に関わらず `po_apply_awaiting_slot` を呼ぶ | `test-awaiting-slot-update.sh` "Req1.1 awaiting-slot 既付与でも po_apply_awaiting_slot が 1 回呼ばれる（バグ修正の本丸）" |
| 1.2 | 呼び出しに最新の `$overlap` / `$overlap_holders_map` を渡している | "Req1.2 apply 呼び出しに最新の overlap=[local-watcher/] と holders={local-watcher/:[42]} が渡される" |
| 1.3 | `po_apply_awaiting_slot` 内部のマーカー検索 → PATCH 経路。新規 create は呼ばない | "Req1.3 既存 marker 付き comment あり → gh api -X PATCH が 1 回呼ばれる" / "Req1.3 / NFR3.1 既存 marker 付き comment あり → gh issue comment（新規 create）は呼ばれない" |
| 1.4 | `po_log` (overlap detected) / `po_warn` (失敗時) で 1 行ログを記録（既存ログ機構そのまま流用） | テスト中の `[owner/test] path-overlap: overlap detected ...` ログ出力で確認 |

### Requirement 2: 既存挙動の後方互換性

| AC | 担保方針 | テストケース |
|---|---|---|
| 2.1 | 未付与 + 既存マーカーなし時の新規付与・新規コメント経路を破壊しない | "Req2.2 awaiting-slot 未付与時に po_apply_awaiting_slot が 1 回呼ばれる（従来挙動）" / "Req2.1 既存 marker なし → gh issue comment（新規 create）が 1 回呼ばれる" |
| 2.2 | `gh issue edit --add-label awaiting-slot` の冪等性（既付与でも error にならない）に依拠 | "Req2.2 / NFR3.1 連続呼び出しでも add-label は決定論的に毎回呼ばれる（gh 側冪等）" |
| 2.3 | overlap 検出時の `return 1`（dispatch skip）を維持 | "Req2.3 overlap 検出時 dispatch skip（return 1）が維持される（既付与/未付与の両ケース）" |
| 2.4 | overlap 自然解消 + 既付与時の `po_clear_awaiting_slot` 経路を維持 | "Req2.4 overlap 空 + awaiting-slot 既付与 → po_clear_awaiting_slot が呼ばれる" / "Req2.4 overlap 空 + clear 成功 → dispatch 続行（return 0）" / "Req2.4 overlap 空 + 未付与 → clear 呼ばれない" |
| 2.5 | `PATH_OVERLAP_CHECK != "true"` で `po_check_dispatch_gate` 冒頭 (L806) が `return 0` し apply/clear/gh が一切呼ばれない | "Req2.5 PATH_OVERLAP_CHECK='off/空/false/0/True/1/enabled' で gate 早期 return 0（dispatch 続行）" / "NFR1.1 ... apply / clear いずれも呼ばれない（差分ゼロ）" |

### Requirement 3: Sticky comment 更新失敗時の挙動

| AC | 担保方針 | テストケース |
|---|---|---|
| 3.1 | `po_apply_awaiting_slot` 失敗時は `po_warn` でログ出力し `return 1` を維持 | "Req3.1 apply 失敗時も po_apply_awaiting_slot は呼ばれる（試行はする）" / "Req3.1 / 3.3 apply 失敗でも dispatch skip 判定（return 1）が維持される" |
| 3.2 | apply 失敗の return 1 は `if ! ...; then ... fi` でキャッチされ exit しない（set -e 下でも継続） | "Req3.2 apply 失敗でも process は異常終了せず後続評価が継続できる（ここまで到達）" |
| 3.3 | apply 失敗時も dispatch 見送り判定 (return 1) と awaiting-slot ラベル状態（既付与なら保持）を維持 | 既付与ケースで apply 失敗 → return 1（dispatch skip 維持）/ ラベルは既に付いているので変化なし |

### NFR

| NFR | 担保方針 |
|---|---|
| NFR 1.1 | `PATH_OVERLAP_CHECK != "true"` 系 7 種の値で apply/clear/gh いずれも呼ばれず差分ゼロを実測 |
| NFR 2.1 | overlap detected / apply 失敗 warn の既存 1 行ログ機構をそのまま使う（candidate 番号は `#${candidate}` 形式で識別可能） |
| NFR 3.1 | `po_apply_awaiting_slot` は内部で「既存 marker 1 件検索 → PATCH」を行うため、複数回呼ばれても sticky comment は Issue あたり 1 件に保たれる。ラベルも `gh issue edit --add-label` の冪等性により 1 件付与状態を維持（連続 2 回呼び出しを fixture で確認） |

## テスト結果

### shellcheck

```
$ shellcheck local-watcher/bin/modules/promote-pipeline.sh
$ echo "EXIT=$?"
EXIT=0

$ shellcheck docs/specs/257-fix-local-watcher-phase-e-path-overlap-a/test-fixtures/test-awaiting-slot-update.sh
$ echo "EXIT=$?"
EXIT=0
```

両方の対象ファイルで警告ゼロ。

### 回帰テスト

```
$ bash docs/specs/257-fix-local-watcher-phase-e-path-overlap-a/test-fixtures/test-awaiting-slot-update.sh
（中略）
----
PASS=31 FAIL=0
EXIT=0
```

31 ケース全 PASS。

### 二重管理ディレクトリの非ドリフト確認

```
$ diff -r .claude/agents repo-template/.claude/agents
$ echo "EXIT=$?"
EXIT=0

$ diff -r .claude/rules repo-template/.claude/rules
$ echo "EXIT=$?"
EXIT=0
```

本 PR では `.claude/agents` / `.claude/rules` を触っていない（差分ゼロ）。

## 確認事項

なし。requirements.md と既存実装 (`po_apply_awaiting_slot` の PATCH/create 分岐が既に存在) のみで
最小差分の修正が成立し、Out of Scope (flock skip 経路 `po__visibility_evaluate_candidate` /
他 marker / ラベル名変更 / opt-in gate 設計変更) にも触れていない。

## 後方互換性確認

| 経路 | 修正前挙動 | 修正後挙動 | 担保 |
|---|---|---|---|
| `PATH_OVERLAP_CHECK != "true"` 全般 | gate 早期 return 0、何もしない | 同左 | "Req2.5 / NFR1.1" 14 ケース |
| overlap 検出 + ラベル未付与 + マーカー comment なし | ラベル新規付与 + sticky comment 新規 create + return 1 | 同左 | "Req2.2 未付与時に apply 1 回呼ばれる" / "Req2.1 既存 marker なし → gh issue comment 1 回" / "Req2.3 return 1 維持" |
| overlap 検出 + ラベル既付与 + マーカー comment あり | apply skip（バグ）/ return 1 のみ | apply 実行（PATCH で comment 上書き）/ return 1 維持 | "Req1.1 既付与でも apply 1 回" / "Req1.3 PATCH 1 回 / 新規 create 0 回" |
| overlap 自然解消 + ラベル既付与 | clear 呼び出し + return 0 | 同左 | "Req2.4 clear 呼ばれる / return 0" |
| overlap 自然解消 + ラベル未付与 | clear 呼ばれない + return 0 | 同左 | "Req2.4 clear 呼ばれない / return 0" |
| apply 失敗時 | warn + return 1（dispatch skip 維持） | 同左 | "Req3.1 / 3.3 return 1 維持" |
| flock skip 経路 `po__visibility_evaluate_candidate` | 未付与時のみ apply（同様のバグ持ち） | **未修正**（Out of Scope） | requirements.md Out of Scope 明記、本 PR では触れない |

### gh API 呼び出し回数の変化

- **`PATH_OVERLAP_CHECK != "true"`**: ゼロ差分（gate 早期 return / NFR 1.1）
- **`PATH_OVERLAP_CHECK = "true"` overlap 検出 + ラベル未付与 + マーカー comment なし**:
  ゼロ差分（修正前後とも 1 サイクルあたり `gh issue edit --add-label` 1 回 +
  `gh issue view --json comments` 1 回 + `gh issue comment` 1 回 = 3 回）
- **`PATH_OVERLAP_CHECK = "true"` overlap 検出 + ラベル既付与 + マーカー comment あり**:
  修正前 0 回 → 修正後 3 回（`add-label` + `issue view` + `api -X PATCH`）。これは本機能の
  本質的な要請（最新ブロッカー情報の PATCH 反映）であり、AC 1.1〜1.3 を満たすための
  意図された増加。NFR 1.1（PATH_OVERLAP_CHECK != true での差分ゼロ）は引き続き維持。

`po_apply_awaiting_slot` 内部の sticky comment は marker 付き 1 件に常時集約されるため
（NFR 3.1）、ラベル / コメントの多重付与は発生しない。

## STATUS

STATUS: complete
