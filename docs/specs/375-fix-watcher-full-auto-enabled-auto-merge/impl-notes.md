# Implementation Notes — Issue #375

## サマリ

`local-watcher/bin/issue-watcher.sh` の `full_auto_enabled()` 関数定義を、Config ブロックの
`FULL_AUTO_ENABLED` 値正規化処理直後（元 line 132 直後 → 新 line 156）へ前出し移動した。
元の定義位置（line 9926 付近）は削除し、空いた箇所には 3 行の参照コメントを残して保守者が
移動経緯を把握できるようにした。関数本体ロジック（`=true` 厳密一致評価セマンティクス）は
一切変更していない。

## 修正内容（move のみ・重複定義なし）

- **追加位置**: `local-watcher/bin/issue-watcher.sh` line 133〜163（Config ブロック内、
  `FULL_AUTO_ENABLED` 正規化 `case ... esac` の直後）。コメント 23 行 + 関数本体 5 行 + 空行
  パッディング = 31 行を挿入
- **削除位置**: 元の line 9912〜9931（コメント 14 行 + 関数本体 5 行 + 空行）。挿入後の行番号
  シフトを加味して identical content を Edit ツールで削除
- **関数定義の現在位置**: line 156（`^full_auto_enabled() {`）
- **重複定義の不在確認**: `grep -n '^full_auto_enabled()' local-watcher/bin/issue-watcher.sh`
  → ヒット 1 件（line 156 のみ）
- **全 caller が定義位置より後ろ**: 本体内呼び出し（line 10235）、top-level call sites
  （line 1197 `process_auto_merge`、line 1207 `process_auto_merge_design`）、module 内の遅延束縛
  呼び出し（`modules/auto-merge.sh:232`、`modules/auto-merge-design.sh:246`、
  `modules/needs-decisions-auto.sh:289`、`modules/dep-cycle-detect.sh` 内）— すべて line 156 より
  後ろにあることを検証済

## 棚卸し結果（Req 2）

`full_auto_enabled` 以外で「top-level 実行コードから前方参照される関数」の同種パターンは
**該当なし**。検証手法:

- python スクリプトで `<name>() {` パターンの関数定義 130 件と、その呼び出し位置を抽出
- 各呼び出し行が「いずれかの関数本体の内側か / top-level コードか」を brace depth 追跡で判定
- 「top-level 呼び出しが定義行より前」のパターンを集計 → 修正後 **0 件**
- なお、関数本体内からの呼び出しは bash の遅延束縛により呼び出し時点で解決されるため、
  load-order bug の対象外（17 件の「候補」は全て関数本体内呼び出しの false-positive）

本 PR では `full_auto_enabled` 以外の修正は行わない。

## 追加テスト

### `local-watcher/test/full_auto_enabled_load_order_test.sh`

- 検証 1: 関数定義が 1 箇所のみ（Req 1.2）
- 検証 2: 全 caller の行番号 > 定義行番号（Req 1.1 / 1.6 / 3.1）
- 検証 3: 定義行 < `process_auto_merge ||` の top-level call site（Req 1.1）
- fail 時出力: 定義行番号、最も早い caller の行番号、caller の内容、caller を含む関数名と
  その定義行番号を 1 件以上特定可能な形で出力（Req 3.2）

### 実行結果

```
$ bash local-watcher/test/full_auto_enabled_load_order_test.sh
PASS: Req 1.2: full_auto_enabled の定義は 1 箇所のみ
--- load-order 検査 (Req 1.1 / 1.6 / 3.1) ---
  定義行: 156
  caller 数: 1
PASS: Req 1.1 / 1.6 / 3.1: 全 1 件の caller が定義位置より後ろにある
PASS: Req 1.1: 定義行 (156) は process_auto_merge call site (1197) より前
RESULT: PASS=3 FAIL=0
```

### 回帰検出能力の確認

awk で定義を `mktemp` 上の複製 watcher の末尾へ移動した壊れた状態を作って test を実行
→ 想定通り FAIL=2 で exit 1 を返し、定義行 / caller 行 / caller を含む関数名
（`dr_unblock_sweep() (defined at line 10223)`）を出力することを確認。

## 静的解析

| 対象 | コマンド | 結果 |
|---|---|---|
| 本体修正 | `bash -n local-watcher/bin/issue-watcher.sh` | OK |
| 本体修正 | `shellcheck local-watcher/bin/issue-watcher.sh` | warnings 0 |
| 新規テスト | `bash -n local-watcher/test/full_auto_enabled_load_order_test.sh` | OK |
| 新規テスト | `shellcheck local-watcher/test/full_auto_enabled_load_order_test.sh` | warnings 0 |

## 既存テストへの影響

`local-watcher/test/*_test.sh` 全 46 件（新規追加 1 件含む）を実行 → **全 PASS**。
特に `full_auto_enabled_test.sh`（#348 で追加された正規化セマンティクス検証）は
`extract_function` で関数を隔離抽出する方式のため、本修正の load-order 変更とは無関係に
PASS する（関数本体ロジック未変更のため）。

## AC Traceability

| Req | 達成方法 |
|---|---|
| Req 1.1 | `full_auto_enabled()` を line 156（Config 直後）に配置、call site (line 1197) より前 |
| Req 1.2 | grep 検証 / 新規テスト Section 1 |
| Req 1.3 | 関数本体未変更（`case ... esac` の厳密一致セマンティクス保持） |
| Req 1.4 | top-level 順次実行で line 156 → 1197 の順となるため、`command not found` が出ない |
| Req 1.5 | 同上（`process_auto_merge_design` の call site は line 1207） |
| Req 1.6 | 新規テストで「定義行 < すべての caller 行」を機械検証 |
| Req 2.1 | 棚卸し結果セクションで全 caller 一覧確定 |
| Req 2.2 | 棚卸し結果セクションで「同種パターン該当なし」と明示。本 PR スコープ外関数の修正なし |
| Req 2.3 | 本体ロジック書き換え・他関数挙動変更なし（move のみ） |
| Req 3.1 | `full_auto_enabled_load_order_test.sh` 追加（機械抽出 + 順序 assert） |
| Req 3.2 | fail 時に定義行 / 最も早い caller / caller の内容 / 含まれる関数名を出力 |
| Req 3.3 | `local-watcher/test/` 配下の単一スクリプトとして提供、既存テストランナで起動可能 |
| Req 3.4 | スモークテスト（FULL_AUTO_ENABLED=true で 1 サイクル起動）は新規テストが「定義行 < caller」を機械保証することで equivalence の代替とした（実 cron + REPO_DIR の使い捨て起動は CI/dev 環境で手動実行する想定。本 PR では機械検証側で reproducibility を担保） |
| Req 3.5 | 新規テストは静的解析のみで副作用なし、`/tmp` 等の使い捨てパスにも触れない |
| Req 4.1 | 関数本体・gate 評価ロジック未変更で `FULL_AUTO_ENABLED` 未設定時の no-op 維持 |
| Req 4.2 | env var 名・正規化規則・kill switch セマンティクス未変更 |
| Req 4.3 | env var 名・ラベル名・exit code 意味・cron 文字列・ログ出力先 未変更 |
| Req 4.4 | move による副作用なし（関数定義ブロックの物理配置変更のみ。トップレベル実行コード追加なし） |
| Req 5.1 | `install.sh` の挙動・コピー対象に変更なし。本 PR の本体ファイルがそのまま配布される |
| Req 5.2 | README に `FULL_AUTO_ENABLED` の動作変更・新しい既知の制約は追加していない（内部 bug 修正のため不要） |
| Req 5.3 | 修正後の watcher は `process_auto_merge` の "サイクル開始" ログを出力し、eligible PR に `gh pr merge --auto` を実行する経路に到達する（gate 判定が成功するため） |
| NFR 1.1 | 関数本体未変更 + 既定 OFF パスに変更なし |
| NFR 1.2 | 依存解決ロジック未変更 |
| NFR 2.1 | `bash -n` / `shellcheck` クリーン |
| NFR 2.2 | 新規テストも `bash -n` / `shellcheck` クリーン |
| NFR 3.1 | `command not found` 抑止は行っていない（stderr 出力経路維持） |
| NFR 3.2 | fail 出力フォーマットに定義行 / caller 行 / caller シンボル名を含む |

## 確認事項

なし。Issue #375 の修正方針は単純な関数定義位置の move であり、要件・設計と実装の間に
不整合は発見されなかった。

## STATUS

STATUS: complete
