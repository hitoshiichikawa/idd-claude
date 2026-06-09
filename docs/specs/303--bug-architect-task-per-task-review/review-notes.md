# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-09T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-303-impl--bug-architect-task-per-task-review
- HEAD commit: d930758a825544e69d408f2f53f2a537d9bdcd0e
- Compared to: main..HEAD
- Mode: design-less impl（tasks.md 不在。Architect 不在で Developer が Open Question 解消を兼ねた単一実装）
- Feature Flag Protocol: opt-out（CLAUDE.md 規定の既定値）→ flag 細目チェックは不適用

## Verified Requirements

- 1.1 — `.claude/rules/tasks-generation.md` 「task-test 境界整合の規約 / Architect への要求」項目 1（同 task 内テスト default の規定）。`architect.md` の対応節項目 1 も同期
- 1.2 — `tasks-generation.md` 「Architect への要求」項目 3（regression coverage / failure path / API・parse failure handling / stale data safety / safety-side fallback の AC を同 task 内テスト必須カテゴリとして列挙）。`architect.md` 項目 3 も同期
- 1.3 — `tasks-generation.md` 「Architect への要求」項目 2（behavior-changing task は最低限の regression / shell-level test を同 task 内に含める）。`architect.md` 項目 2 も同期
- 1.4 — `tasks-generation.md` 「partial 明示の canonical 記法」節（deferred 時は `_Requirements_partial:_` 明示か `_Requirements:_` から除外を要求）
- 1.5 — 同節（独立アノテーション方式 `_Requirements_partial:_` を 1 つに固定、行内サフィックス / 散文 / HTML コメント方式を禁止と明記）
- 2.1 — `tasks-generation.md` 「dedicated regression test task の境界制約」項目 1（`_Requirements:_` の重複制御 / partial 解消関係明示）
- 2.2 — 同節項目 2（E2E / 統合テスト / coverage 補完等にスコープ限定、単体テストが先行 AC 直結なら先行 task に含める）
- 2.3 — 同節項目 3（partial 解消の責務と deferred 先 task の明示要求）
- 3.1 — `.claude/agents/developer.md` 「task-test 境界整合の責務」節「当該 task 内のテスト実装責務」項目
- 3.2 — 同節「同 task 内テストが書けないとき」項目（spec 書き換え禁止 + PR 本文「確認事項」/ Issue コメントでの差し戻し提案）
- 3.3 — `.claude/agents/reviewer.md` 「task-test 境界整合と partial 明示の取り扱い」節「partial 明示なし AC は通常通り `missing test` 判定」項目
- 3.4 — `reviewer.md` 同節「`_Requirements_partial:_` 明示 AC は `missing test` reject 理由としない」項目（および subset 妥当性違反は `boundary 逸脱` 細目 partial spec violation で reject）
- 3.5 — `tasks-generation.md` の「task-test 境界整合の規約」節を Architect / Developer / Reviewer 共通参照点として宣言。`architect.md` / `developer.md` / `reviewer.md` の各更新箇所が `tasks-generation.md` への cross-link を持ち、3 agents が同一 contract を参照する構造
- 4.1 — root `.claude/agents/architect.md` と `repo-template/.claude/agents/architect.md` / root `.claude/rules/tasks-generation.md` と `repo-template/.claude/rules/tasks-generation.md` が同一 PR で同期反映
- 4.2 — root `.claude/agents/developer.md` / `reviewer.md` と `repo-template/.claude/agents/developer.md` / `reviewer.md` が同一 PR で同期反映
- 4.3 — `diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules` をレビュー時に再実行し、両方とも出力なし（exit 0）であることを確認
- 5.1 — `tasks-generation.md` 新節冒頭で「`PER_TASK_LOOP_ENABLED` 未指定 / `=true` 以外では本節は適用されず、既存単一 Developer 一括実装フローの挙動は変化しない」を明示。`architect.md` 新節末尾でも同旨を明示
- 5.2 — `tasks-generation.md` 「後方互換性」節「既に main に merge 済みの `tasks.md` に対する遡及的な書き換えは要求しない」項目
- 5.3 — 同節「既存の `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` / `- [ ]*` の各アノテーション規約を破壊的に変更しない」項目（`_Requirements_partial:_` は新規 optional 追加であり既存パースを破壊しない旨も明示）
- NFR 1.1 — `tasks-generation.md` / `architect.md` / `developer.md` / `reviewer.md` 新節すべてで opt-out 既定環境への非適用を明示
- NFR 1.2 — 同上（既存単一 Developer 一括実装フローの挙動非変更）
- NFR 1.3 — `tasks-generation.md` 「後方互換性」節で `_Requirements_partial:_` 行が既存 Mechanical Checks（checkbox enforcement / Budget overflow / verify block well-formed）の判定パターンにマッチしないことを明示
- NFR 2.1 — `_Requirements_partial:_` を既存アノテーション表に追加し、同スタイル（アンダースコア + キー + 値）で整合
- NFR 2.2 — root / repo-template byte 一致が `diff -r` で空（NFR 2.2 / Req 4.3 と整合）
- NFR 2.3 — partial 明示の canonical を独立アノテーション方式 1 つに固定し、代替記法を **禁止** と明記
- NFR 3.1 — `docs/specs/303--bug-architect-task-per-task-review/test-fixtures/` 配下の 3 fixture（`tasks-violation.md` / `tasks-partial-ok.md` / `tasks-same-task-ok.md`）と awk ベース検出スクリプト `test-task-boundary.sh` で機械的検証構造を持つ。レビュー時に `bash test-task-boundary.sh` を再実行し pass=3 fail=0 を確認。`shellcheck test-task-boundary.sh` も exit 0

## Findings

なし

## Summary

Issue #303 の AC（Req 1〜5 / NFR 1〜3）はすべて、`.claude/rules/tasks-generation.md` の新節、
`.claude/agents/{architect,developer,reviewer}.md` の対応節追記、および `test-fixtures/` 配下の
3 fixture + awk 検証スクリプトでカバーされている。root と `repo-template/` の byte 同期も
`diff -r` 再実行で空であることを確認した。fixture スモークテスト（pass=3 fail=0）と
`shellcheck` も成功。design-less impl のため tasks.md が無く `_Boundary:_` を比較する正本は
存在しないが、変更ファイルはすべて本 Issue のスコープ（rule / agent 更新 / 二重管理同期 /
fixture 配置）に整合しており boundary 逸脱は検出されない。

RESULT: approve
