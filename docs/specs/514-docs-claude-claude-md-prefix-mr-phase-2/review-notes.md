# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-07-23T10:05:00Z -->

## Reviewed Scope

- Branch: claude/issue-514-impl-docs-claude-claude-md-prefix-mr-phase-2
- HEAD commit: daff20309a2900beceff82934b6087177d14922c
- Compared to: main..HEAD
- 差分: `CLAUDE.md`（1 行変更）+ spec 成果物 2 件（`requirements.md` / `impl-notes.md`）
- `tasks.md` / `design.md` は不在（design-less impl）。`_Boundary:_` アノテーションが存在しない
  ため、境界判定は requirements.md Requirement 4（変更範囲の限定）を代替の境界契約として適用した
- Feature Flag Protocol: `CLAUDE.md` に `## Feature Flag Protocol` 節が存在しない
  （`.claude/rules/` 参照表の 1 行のみ）→ opt-in 宣言なしと判定し、flag 観点の細目は適用せず
  通常の 3 カテゴリ判定のみを実施

## Verified Requirements

- 1.1 — `CLAUDE.md:239` の `mr_` 行に `#508 Phase 2 / ...` を追記。Issue 番号付きで Phase 2 の由来を明示
- 1.2 — 同行に「`size:*` ラベルから Developer 実行モデルを決める解決規則を純粋関数で提供」を記載
- 1.3 — 同行に `mr_extract_size_label` / `mr_resolve_dev_model` の 2 関数名を記載
- 1.4 — 同行に `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM` を記載
- 1.5 — 同行に「slot 起動時点のラベル集合で 1 回だけ解決して当該 slot 内の `DEV_MODEL` を再代入する」を記載
- 1.6 — 同行に「gate 有効化と size 別モデル設定の明示の両方を要する二重 opt-in」を記載
- 2.1 — `git diff main..HEAD -- CLAUDE.md` 上、`#507 Phase 1 / Triage complexity の解釈と `size:*` ラベル永続化。` の部分は原文のまま行頭に温存（削除・改変なし）
- 2.2 — 「gate `MODEL_ROUTING_ENABLED` は Phase 共通の単一 gate で Phase 別 gate を設けない」が行末に残存
- 2.3 — prefix 列は `` `mr_` `` のまま（diff 上、セル 1 列目に変更なし）
- 2.4 — 行位置は `po_` 行と `pr_` 行の間（`CLAUDE.md:239`）で不変。diff は同一行の 1:1 置換（`-1 +1`）
- 2.5 — 変更行は 1 行のみ。`git diff --stat` = `CLAUDE.md | 2 +-`（他行に差分なし）
- 2.6 — 表 232〜258 行の `|` 個数を awk 集計し全行 `pipes=3`（2 列構造維持）。`mr_` 行はセル内改行なしの 1 行
- 3.1 — `pr_` / `pi_` / `fr_` 行と同水準の「Issue 番号 + 責務要約 + 関数名の短い括弧注記」。引数 / rc / 分岐条件といった逐次仕様は含めておらず、module 冒頭ヘッダ・README に委譲されている
- 3.2 — 追記部の説明文は日本語ベース
- 3.3 — 関数名 / env var 名 / ラベル名 / module 名を英語のまま表記（日本語への言い換えなし）
- 3.4 — `mr_extract_size_label` / `mr_resolve_dev_model` / `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM` / `DEV_MODEL` / `size:*` / `_slot_apply_dev_model_routing` / `MODEL_ROUTING_ENABLED` をすべてインラインコード記法で表記（module 名 `slot-worker` を bare 表記する点は既存表の他行と同一慣習）
- 3.5 — `CLAUDE.md:239` は 855 バイトの 1 行（セル内改行なし）
- 4.1 — 実体変更は `CLAUDE.md` 1 ファイルのみ。同梱の `requirements.md` / `impl-notes.md` はワークフロー上必須の spec 成果物（CLAUDE.md エージェント連携ルール）であり本 AC の「変更対象」には当たらないと解した
- 4.2 — `git diff --stat` = 1 insertion / 1 deletion。変更行は prefix 表の `mr_` 行 1 行のみ
- 4.3 — `git diff --name-only main..HEAD` に `repo-template/` 配下のファイルなし
- 4.4 — 同上、`local-watcher/` 配下のファイルなし
- 4.5 — 同上、`README.md` なし
- 4.6 — `slot-worker` 行の `_slot_apply_dev_model_routing` 欠落ドリフトを本件に含めず、`impl-notes.md`「確認事項」で別 Issue 判断へ回している
- 5.1 — `grep '^mr_extract_size_label()'` / `'^mr_resolve_dev_model()'` が `local-watcher/bin/modules/model-router.sh:252` / `:306` に、`_slot_apply_dev_model_routing()` が `slot-worker.sh:207` に実在。行内に実在しない関数名の記載なし
- 5.2 — 行内の gate 名は `MODEL_ROUTING_ENABLED` のみ（他 gate 名の記載なし）
- 5.3 — `model-router.sh` の Phase 2 ヘッダ（厳密一致 1 件のみ採用 / `DEV_MODEL_SMALL` `DEV_MODEL_MEDIUM` 非空時のみ採用 / それ以外は `DEV_MODEL` へ fail-safe）および README:1582「Model Routing Phase 2」節（二重 opt-in / slot 起動時 1 回解決 / Phase 共通の単一 gate）と突き合わせ、矛盾する記述なし
- 5.4 — 「gate 判定・解決結果の適用・ログ出力は呼び出し側 slot-worker の `_slot_apply_dev_model_routing` が担い」と帰属を分離。`slot-worker.sh:203-205` のヘッダ（gate 判定を Slot Runner 側に置く旨）と一致し、呼び出し側責務を model-router の責務として記載していない
- 5.5 — 行内に `Phase 3` / `#509` の記載なし（grep 不在確認）
- 6.1 — 検証手順として `git diff --stat` / `--name-only` による 1 ファイル・1 行確認を実施（impl-notes.md「検証結果」表にも記載）
- 6.2 — Requirement 1 の記載要素 9 点をすべて更新後の行に対して確認（上記 1.1〜1.6）
- 6.3 — Phase 1 記述と単一 gate 記述の残存を diff 上で確認（上記 2.1 / 2.2）
- 6.4 — 表 232〜258 行の全行が 2 列（`pipes=3`）であることを確認（上記 2.6）
- 6.5 — コード変更を伴わないため `shellcheck` / `actionlint` / 近接テストは要求されない。本件では実際にコード差分ゼロであり、テスト追加なしが AC 準拠
- NFR 1.1 — 表行数の増加は 0（1 行 → 1 行の置換）
- NFR 1.2 — `mr_` 行は 855 バイトで、表内最長行（`slot-worker` 行 1185 / `impl-pipeline` 行 1103 / `pt_` 行 1004）を下回る
- NFR 2.1 — `diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules repo-template/.claude/rules` ともに出力なし（空）を再実行して確認
- NFR 2.2 — `#507 Phase 1 / ...` と `#508 Phase 2 / ...` を Phase 単位で並置し、同一書式で Phase 3 を追記できる構造

## Findings

なし

## Summary

`CLAUDE.md` prefix 表 `mr_` 行の 1 行更新のみで、Requirement 1〜6 / NFR 1〜2 の全 numeric ID を
実装差分および既存コード（`model-router.sh` / `slot-worker.sh` / README:1582）との突き合わせで
確認できた。boundary は tasks.md 不在のため Requirement 4 を代替契約として評価し、変更が
root `CLAUDE.md` 1 ファイル・1 行に収まっていることを確認。コード変更ゼロのドキュメント更新で
Req 6.5 がテスト追加を明示的に不要としているため missing test も該当しない。
なお `slot-worker` 行への `_slot_apply_dev_model_routing` 未記載ドリフトは Out of Scope 宣言と
Open Questions で別 Issue 判断へ回されており、当該 impl PR の reject 理由には含めない
（設計レベルの指摘として別 Issue へ還流すべき事項）。

RESULT: approve
