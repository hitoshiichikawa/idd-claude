# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T10:30:00Z -->

## Reviewed Scope

- Branch: claude/issue-375-impl-fix-watcher-full-auto-enabled-auto-merge
- HEAD commit: 2ed97e43c2b7c017a7211d8340486e426fc0b202
- Compared to: main..HEAD
- 変更ファイル (4 件):
  - `local-watcher/bin/issue-watcher.sh` (move のみ: -20/+29 行)
  - `local-watcher/test/full_auto_enabled_load_order_test.sh` (新規 179 行)
  - `docs/specs/375-.../requirements.md` (新規)
  - `docs/specs/375-.../impl-notes.md` (新規)
- 注記: 本 Issue は `tasks.md` / `design.md` が生成されない単純な move 修正であり、
  `_Boundary:_` アノテーションは存在しない。判定は requirements.md の AC を基準に行う。

## Verified Requirements

### Requirement 1: load-order bug の解消（`full_auto_enabled` 定義の前出し）

- 1.1 — `full_auto_enabled()` の定義が `local-watcher/bin/issue-watcher.sh:156` に配置され、
  Config ブロックの `FULL_AUTO_ENABLED` 正規化 (`case ... esac` line 129–132) 直後、かつ
  最も早い top-level call site (line 1197 `process_auto_merge`) より前であることを diff /
  `grep -n '^full_auto_enabled() {'` で確認
- 1.2 — `grep -n '^full_auto_enabled() {' local-watcher/bin/issue-watcher.sh` → 1 件のみ
  (line 156)。重複定義なし。元 line 9926 相当の定義ブロックは削除済み (新 line 9941–9943 は
  3 行の参照コメントのみ)
- 1.3 — diff の `full_auto_enabled() { case "${FULL_AUTO_ENABLED:-false}" in true) return 0;; *) return 1;; esac }`
  が move 前後で完全一致。関数本体ロジック未変更
- 1.4 — top-level 順次実行で line 156 (def) → line 1197 (`process_auto_merge` call) の順となる
  ため、`full_auto_enabled: command not found` (rc=127) は発生しない
- 1.5 — 同様に line 156 → line 1207 (`process_auto_merge_design` call) の順
- 1.6 — `local-watcher/test/full_auto_enabled_load_order_test.sh` が「定義行 < すべての
  caller 行」を機械検証 (test 実行結果 PASS=3 FAIL=0 を当方でも再実行確認)

### Requirement 2: 前方参照の棚卸し

- 2.1 — caller 一覧確定: 本体 `issue-watcher.sh:10235` (`dr_unblock_sweep` 関数本体内、遅延束縛)、
  top-level call sites `process_auto_merge` / `process_auto_merge_design` (これらの関数定義は
  modules 経由)、modules 内 `auto-merge.sh:232` / `auto-merge-design.sh:246` /
  `needs-decisions-auto.sh:289` (いずれも関数本体内・遅延束縛)。すべて line 156 より後ろ
- 2.2 — `full_auto_enabled` 以外の関数で「top-level からの前方参照」パターンは impl-notes に
  記載の検証手法で 0 件と確定 (本 PR ではスコープ外、別 Issue 化なし)
- 2.3 — diff を見る限り本体ロジック書き換え・他関数挙動変更なし (move のみ)

### Requirement 3: 回帰防止テスト

- 3.1 — `local-watcher/test/full_auto_enabled_load_order_test.sh` が定義行と全 caller を
  機械抽出し「定義行 < caller 行」を assert
- 3.2 — test fail 時の出力フォーマットに `定義行` / `caller 行` / `caller 内容` /
  `caller シンボル` (含まれる関数名と定義行) を含む (test 内 awk による enclosing_symbol
  取得ロジックを Read で確認)
- 3.3 — 既存 `local-watcher/test/` 配下の単一 bash スクリプトとして提供。当方で
  `bash local-watcher/test/full_auto_enabled_load_order_test.sh` を実行し PASS 確認
- 3.4 — impl-notes.md にて「機械的な順序保証は smoke test (FULL_AUTO_ENABLED=true で 1 サイクル
  起動) と equivalence の代替」とする substitution が明示宣言されている。static check は
  load-order 違反を構造的に検出する点で smoke 起動より strict (current 状態だけでなく全
  caller を網羅) なため、AC の趣旨 (`stub 隔離では再現不可だったケースをカバーする`) を
  満たすと判断。Developer の責任で impl-notes に紐付けが書かれているため `missing test`
  には該当しない
- 3.5 — 追加 test は静的解析のみで `/tmp` 等への副作用なし

### Requirement 4: 後方互換と既定動作の温存

- 4.1 — 関数本体 (`case "${FULL_AUTO_ENABLED:-false}" in true) return 0;; *) return 1;; esac`)
  未変更 + 既定 OFF パス未変更により default-off の外部副作用ゼロ維持
- 4.2 — `FULL_AUTO_ENABLED` env var 名・正規化規則・kill switch セマンティクスに diff なし
- 4.3 — `AUTO_MERGE_ENABLED` / `AUTO_MERGE_DESIGN_ENABLED` / ラベル名 / exit code / cron
  文字列 / ログ出力先すべて未変更 (diff に該当箇所なし)
- 4.4 — diff は関数定義ブロックの物理配置移動のみ。新規 top-level 実行コード注入なし
  (移動先 line 133–161 は関数定義 + コメントのみ。移動元の削除箇所はコメント 3 行のみが
  残置)

### Requirement 5: 同期と配布の整合性

- 5.1 — `install.sh` に diff なし。`$HOME/bin/issue-watcher.sh` への冪等コピー挙動は維持
- 5.2 — README に diff なし。動作変更を伴わない内部 bug 修正のため不要 (NFR 1.1 整合)
- 5.3 — 修正後の経路は line 156 (def) → line 1197 (call) → `process_auto_merge` 関数本体内で
  `full_auto_enabled` 評価が `true` に解決される。`gh pr merge --auto` 到達経路に
  load-order 起因の no-op なし (機能的整合性は新規 test の静的検証で担保)

### Non-Functional Requirements

- NFR 1.1 — 関数本体未変更 + 既定 OFF パス未変更 → 既存外部観測挙動と一致
- NFR 1.2 — 依存解決ロジック (`command -v` 群) 未変更
- NFR 2.1 — 当方で `bash -n local-watcher/bin/issue-watcher.sh` (OK) + `shellcheck` (warnings 0)
  を再実行して確認
- NFR 2.2 — 新規 test も `bash -n` / `shellcheck` クリーン (当方で再実行確認)
- NFR 3.1 — `full_auto_enabled: command not found` を握り潰す処理は導入されていない
  (stderr 抑止コードなし)
- NFR 3.2 — fail 出力フォーマットに `定義行` / `最も早い caller 行` / `caller シンボル名`
  を含む (test 実装を Read で確認)

## Findings

なし。

## Summary

`full_auto_enabled()` の関数定義を `issue-watcher.sh` の Config ブロック直後 (line 156) へ
前出し移動するキーストーン修正。move のみで関数本体・gate セマンティクス・env var 名・
ラベル名・install.sh・README いずれにも diff なし。`local-watcher/test/full_auto_enabled_load_order_test.sh`
が「定義行 < 全 caller 行」を機械検証する近接 test として追加され、当方で実行 PASS を確認。
`bash -n` / `shellcheck` クリーン、既存 `full_auto_enabled_test.sh` (正規化セマンティクス検証)
も PASS。Req 3.4 (smoke test) の substitution は impl-notes に明示宣言済みで、static check が
構造的に strict であるため AC の趣旨を満たすと判断。boundary 逸脱なし、AC 全件カバー、
missing test なし。

RESULT: approve
