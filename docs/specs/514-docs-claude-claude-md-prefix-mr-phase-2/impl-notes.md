# 実装ノート — #514 CLAUDE.md prefix 表 `mr_` 行への Phase 2 責務追記

## 変更概要

root `CLAUDE.md`「機能追加ガイドライン」§2 prefix ⇄ module 対応表の `mr_` 行（`CLAUDE.md:239`）
1 行のみを更新し、#508（Phase 2 / merge 済み）で model-router に追加された「`size:*` ラベル →
Developer 実行モデル解決」の責務を追記した。既存の Phase 1（#507）記述と単一 gate 記述は
原文のまま温存している。

変更ファイル: `CLAUDE.md` の 1 ファイル・1 行（`git diff --numstat` = `1 1 CLAUDE.md`）。
コード変更なし（design.md / tasks.md は本 Issue では未作成のため、requirements.md の AC を
直接検証観点として消化した）。

## 実装上の判断

- **Phase の区切り書式**: NFR 2.2 は `Phase N（#Issue番号）: 責務` を例示するが、既存 Phase 1
  記述は `#507 Phase 1 / ...` 形式であり、Req 2.1（Phase 1 記述を改変せず保持）を優先して
  既存書式に合わせ `#508 Phase 2 / ...` を並置した。将来 Phase 3 は同じ書式で `#509 Phase 3 / ...`
  を追記でき、NFR 2.2 の意図（Phase 単位の区切り・追記可能な同一書式）は満たしている。
- **呼び出し側責務の帰属（Req 5.4）**: gate 判定 / `DEV_MODEL` への適用 / ログ出力は model-router
  ではなく slot-worker 側の責務であるため、「gate 判定・解決結果の適用・ログ出力は呼び出し側
  slot-worker の `_slot_apply_dev_model_routing` が担い」と明示的に帰属を分けて記述した。
  Req 1.5（slot 起動時 1 回解決・`DEV_MODEL` 再代入）は同一文中で呼び出し側の挙動として記述して
  いる。なお `slot-worker` 行への `_slot_apply_dev_model_routing` 追記は Out of Scope のため
  行っていない（`mr_` 行内での言及のみ）。
- **記述粒度（Req 3.1）**: `pr_` / `pi_` / `fr_` 行と同様に「関数名 + 短い括弧書きの役割要約」に
  留め、引数・rc・fail-safe の分岐条件といった逐次仕様は module 冒頭ヘッダと README に委ねた。

## AC トレーサビリティ

コード変更を伴わないドキュメント更新のため、検証は Requirement 6 が定める確認手段
（差分範囲確認 / 記載要素の grep 確認 / 表構造確認）で行った（Req 6.5 により
`shellcheck` / `actionlint` / 近接テストの追加は要求されない）。

| 要件 ID | 担保内容（検証手段） |
|---|---|
| 1.1 | 更新後 `mr_` 行に `#508 Phase 2` を記載（grep OK） |
| 1.2 | 「`size:*` ラベルから Developer 実行モデルを決める解決規則」を記載（grep OK） |
| 1.3 | `mr_extract_size_label` / `mr_resolve_dev_model` を記載（grep OK） |
| 1.4 | `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM` を記載（grep OK） |
| 1.5 | 「slot 起動時点のラベル集合で 1 回だけ解決して当該 slot 内の `DEV_MODEL` を再代入」を記載（grep OK） |
| 1.6 | 「gate 有効化と size 別モデル設定の明示の両方を要する二重 opt-in」を記載（grep OK） |
| 2.1 | `#507 Phase 1 / Triage complexity の解釈と `size:*` ラベル永続化` を原文のまま保持（`git diff` 上で当該部分に差分なし） |
| 2.2 | 「gate `MODEL_ROUTING_ENABLED` は Phase 共通の単一 gate で Phase 別 gate を設けない」を末尾に保持（grep OK） |
| 2.3 | prefix 列は `` `mr_` `` のまま（`git diff` で列頭に差分なし） |
| 2.4 | 行位置は `po_` 行と `pr_` 行の間（`CLAUDE.md:239`）で不変（`git diff --numstat` = 1 行入替のみ） |
| 2.5 | 変更行は 1 行のみ（`git diff --numstat` = `1 1`）。他行に差分なし |
| 2.6 | 表全行の `\|` 個数が 3（= 2 列）であることを awk で確認（232〜258 行すべて `pipes=3`） |
| 3.1 | `pr_` / `pi_` / `fr_` 行と同水準の「Issue 番号 + 責務要約 + 関数名の短い括弧注記」に統一（目視確認） |
| 3.2 | 説明部は日本語ベース（目視確認） |
| 3.3 | 関数名 / env var 名 / ラベル名 / module 名は英語表記のまま（目視確認） |
| 3.4 | 全識別子をインラインコード記法で表記（目視確認） |
| 3.5 | セル内改行なしの 1 行（`sed -n '239p'` で 1 行として取得可能） |
| 4.1 | `git diff --name-only` = `CLAUDE.md` のみ |
| 4.2 | `git diff --numstat` = `1 1 CLAUDE.md`（`mr_` 行 1 行のみ） |
| 4.3 | `repo-template/` 配下に差分なし（`git status --short` で未変更） |
| 4.4 | `local-watcher/` 配下に差分なし（同上） |
| 4.5 | `README.md` に差分なし（同上） |
| 4.6 | `mr_` 行以外の変更は不要と判断。`slot-worker` 行のドリフトは Out of Scope として別 Issue 判断へ（下記「確認事項」） |
| 5.1 | `mr_extract_size_label` / `mr_resolve_dev_model` が `local-watcher/bin/modules/model-router.sh` に、`_slot_apply_dev_model_routing` が `local-watcher/bin/modules/slot-worker.sh` に実在することを `grep -c '^<fn>()'` = 1 で確認 |
| 5.2 | 行内の gate 名は `MODEL_ROUTING_ENABLED` のみ（`grep -oE '[A-Z_]+_(ENABLED\|MODE)'` の結果は `MODEL_ROUTING_ENABLED` のみ。`DEV_MODE` は `DEV_MODEL` の部分一致による誤検出） |
| 5.3 | #508 requirements.md（Req 1.1〜1.8 / 5.1〜5.3）および README「Model Routing Phase 2」節（`README.md:1582`）の記述と突き合わせ、二重 opt-in / slot 起動時 1 回解決 / large は `DEV_MODEL` の各点で矛盾がないことを確認 |
| 5.4 | gate 判定 / `DEV_MODEL` 適用 / ログ出力を呼び出し側 slot-worker の責務として明記し、model-router の責務としては記載していない |
| 5.5 | 行内に `Phase 3` / `#509` の記載なし（grep で不在確認） |
| 6.1〜6.4 | 本表の 4.1 / 4.2（差分範囲）、1.1〜1.6（記載要素）、2.1 / 2.2（既存記述残存）、2.6（表構造）で実施済み |
| 6.5 | コード変更がないため `shellcheck` / `actionlint` / 新規テストは実施・追加していない |
| NFR 1.1 | 表の行数は増加 0（1 行を 1 行に置換） |
| NFR 1.2 | 更新後 `mr_` 行は 855 バイト。表内最長行（`slot-worker` 行 1185 / `impl-pipeline` 行 1103 / `pt_` 行 1004）を下回る |
| NFR 2.1 | `diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules repo-template/.claude/rules` ともに出力なし（空） |
| NFR 2.2 | `#507 Phase 1 / ...`・`#508 Phase 2 / ...` と Phase 単位で区切り、同一書式での Phase 追記が可能（上記「実装上の判断」参照） |

## 検証結果

| 検証 | コマンド | 結果 |
|---|---|---|
| 差分範囲 | `git diff --name-only` / `git diff --numstat` | `CLAUDE.md` のみ / `1 1`（1 行変更） |
| 表構造 | 232〜258 行の `\|` 個数を awk 集計 | 全行 `pipes=3`（2 列を維持） |
| 記載要素 | 更新行に対する 13 トークンの grep | すべて OK |
| 関数実在 | `grep -c '^<fn>()' modules/{model-router,slot-worker}.sh` | 3 関数とも 1 件ヒット |
| agents 同期 | `diff -r .claude/agents repo-template/.claude/agents` | 差分なし |
| rules 同期 | `diff -r .claude/rules repo-template/.claude/rules` | 差分なし |

コード変更がないため `shellcheck` / `actionlint` / 近接テストは対象外（Req 6.5）。

## 確認事項

- **`slot-worker` 行の呼び出し側関数のドリフト**: requirements.md の Open Questions にあるとおり、
  #508 で追加された `_slot_apply_dev_model_routing` は `slot-worker.sh` 冒頭ヘッダには記載済みだが
  CLAUDE.md の `slot-worker` 行の関数列挙には含まれていない。本 Issue は `mr_` 行 1 行に限定
  （Req 4.2）のため対応していない。別 Issue として起票するかは人間判断に委ねる。
- **NFR 2.2 の書式と Req 2.1 の温存の優先順位**: 上記「実装上の判断」のとおり、既存 Phase 1 記述の
  温存（Req 2.1）を優先して `#508 Phase 2 / ...` 形式を採用した。`Phase N（#Issue番号）: 責務`
  という厳密書式への統一が必要なら Phase 1 記述の書式変更を伴うため、別途判断が必要。

STATUS: complete
