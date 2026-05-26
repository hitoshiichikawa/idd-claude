<!-- SPDX-License-Identifier: MIT -->

# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-26T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-230-impl-feat-watcher-stage-a-verify-design-less
- HEAD commit: cb5a78d
- Compared to: main..HEAD
- ルート: PM → Developer の design-less ルート（Architect 未経由）。`design.md` / `tasks.md` は存在せず、AC 正本は `requirements.md`
- スコープ: Req 1〜4 / NFR 1〜4。Req 5（Reviewer backstop）はオーケストレータ判断で本 PR 見送り（条件付き要件・他要件非破綻のため reject 対象外）
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out 解釈。flag 観点の確認は行わない（通常 3 カテゴリ判定）

## Verified Requirements

- 1.1 — design-less（tasks.md 不在）で verify を推測せず SKIP。`stage-a-verify.sh` 既存挙動（resolve 全段 return 1）/ `test-design-less-skip.sh` ケース 1 で `resolve rc=1` を assert（実行で PASS 確認）
- 1.2 — SKIPPED ログ書式（`stage-a-verify: SKIPPED reason=no-verify-task-in-tasks-md` 3 段 prefix）。`stage_a_verify_run` Gate 2 既存挙動 / test ケース 4 で grep assert
- 1.3 — round counter 不増 / 失敗扱いにしない。Gate 2 は round に触れず return 0 / test ケース 4 で round before==after を assert
- 1.4 — SKIP 判定で tasks.md を書き換えない。resolve は参照のみ / test ケース 1〜3 で tasks.md 非生成を assert
- 2.1 — README「design-less impl（tasks.md 不在）は gate 対象外（意図された仕様）」節で意図仕様として明記
- 2.2 — README「design-less impl の regression 担保」節（Developer テスト + Reviewer AC 判定）
- 2.3 — README「構造化 verify ブロックを持つ Architect ルートは gate 対象（SKIP の例外）」節で区別記載
- 3.1 — README「検討の上で不採用とした代替案」節 代替案 (a) 汎用 repo 標準 verifier 自動判定の不採用と理由
- 3.2 — 同節 代替案 (c) PM への verify-AC 必須化の不採用と理由
- 3.3 — 同節末尾 採用方針が「推測しない」設計思想（#224 / #228）と整合する旨
- 4.1 — README 後始末節 撤去前提条件（#224 マージ・デプロイ・E2E 完了）を明記
- 4.2 — 同節 #224 完了後に cron / launchd から撤去できる旨
- 4.3 — 同節「撤去後の挙動」（Architect ルートは構造化ブロックで解決 / design-less は SKIP に戻る）
- 4.4 — 同節「解決順序における優先度」（構造化ブロックが env より優先）+ 既存解決順序節
- 4.5 — 同節「repo-default として残す選択肢」/ test ケース 3 で env 採用（rc=0）を assert
- NFR 1.1〜1.5 — env var 名 / ラベル / exit code / ログ書式 / round 契約の後方互換。`stage-a-verify.sh` 差分は追加のみ・コメント 9 行のみ（削除ゼロ・ロジック変更ゼロを機械確認）。shellcheck 警告ゼロ
- NFR 2.1 / 2.2 — README 後始末節（撤去前提条件 / リポジトリ外オペレータ作業）で記載
- NFR 4.1 / 4.2 — test ケース 2（冪等 2 回目）で rc=1 を再確認 / resolve 冒頭の source 初期化により前回残値非依存

## Findings

なし

## Summary

Req 1〜4 / NFR 1〜4 の全 numeric ID が README / 各 rule の追記とコメントで明文化され、回帰
スモークテスト（`test-design-less-skip.sh`）が PASS=4 FAIL=0、#224 既存テストも 14 ケース全通過、
shellcheck 警告ゼロ。`local-watcher/` への変更はコメント追記のみで挙動・ログ書式・exit code・
env var 名・round 契約を一切変えず後方互換を維持しており、boundary 逸脱には当たらない。AC 未カバー /
missing test / boundary 逸脱のいずれも検出されない。Req 5 はオーケストレータ判断による見送りで
条件付き要件のため reject 対象外。

RESULT: approve
