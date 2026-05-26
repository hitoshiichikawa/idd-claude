<!-- SPDX-License-Identifier: MIT -->

# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-26T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-230-impl-feat-watcher-stage-a-verify-design-less
- HEAD commit: bc324768ad97b2436dcf7dc0aafd31bb0fee4f42
- Compared to: main..HEAD
- ルート: PM → Developer の design-less ルート（Architect 未経由）。`design.md` / `tasks.md` は存在せず、AC 正本は `requirements.md`。`_Boundary:_` アノテーション不在のため、変更ファイルが requirements の Out of Scope を侵さず本件の意図に収まるかで boundary を評価
- スコープ: Req 1〜4 / NFR 1〜4。Req 5（Reviewer backstop）はオーケストレータ判断で本 PR 見送り（条件付き要件・他要件非破綻のため reject 対象外）
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out 解釈。flag 観点の確認は行わない（通常 3 カテゴリ判定）

## Verified Requirements

- 1.1 — design-less（tasks.md 不在）で verify を推測せず SKIP。`local-watcher/bin/modules/stage-a-verify.sh` の resolve 全段 return 1（既存 #224 挙動）/ `test-design-less-skip.sh` ケース 1・2 で `resolve rc=1` を assert（独立再実行で PASS 確認）
- 1.2 — SKIPPED ログ書式（`stage-a-verify: SKIPPED reason=no-verify-task-in-tasks-md`）。`stage-a-verify.sh:694` の `sav_log "SKIPPED reason=no-verify-task-in-tasks-md"` / test ケース 4 で grep assert（PASS 確認）
- 1.3 — round counter 不増 / 失敗扱いにしない。Gate 2 は round に触れず return 0 / test ケース 4 で round before==after + rc=0 を assert
- 1.4 — SKIP 判定で tasks.md を書き換えない。resolve は参照のみ / test ケース 1〜3 で tasks.md 非生成を assert
- 2.1 — README「design-less impl（tasks.md 不在）は gate 対象外（意図された仕様）」節で意図仕様として明記 + tasks-generation.md / design-review-gate.md への補足追記
- 2.2 — README「design-less impl の regression 担保」節（Developer テスト + Reviewer AC 判定）
- 2.3 — README「構造化 verify ブロックを持つ Architect ルートは gate 対象（SKIP の例外）」節で区別記載
- 3.1 — README「検討の上で不採用とした代替案」節 代替案 (a) 汎用 repo 標準 verifier 自動判定の不採用と理由
- 3.2 — 同節 代替案 (c) PM への verify-AC 必須化の不採用と理由（EARS 実装語彙混入チェックとの矛盾を記載）
- 3.3 — 同節末尾 採用方針が「推測しない」設計思想（#224 / #228）と整合する旨
- 4.1 — README 後始末節 撤去前提条件（#224 マージ・デプロイ・E2E 完了）を明記
- 4.2 — 同節 #224 完了後に cron / launchd から撤去できる旨
- 4.3 — 同節「撤去後の挙動」（Architect ルートは構造化ブロックで解決 / design-less は SKIP に戻る）
- 4.4 — 同節「解決順序における優先度」（構造化ブロックが env より優先）+ 既存解決順序節
- 4.5 — 同節「repo-default として残す選択肢」/ test ケース 3 で env 採用（rc=0）を assert
- 5.1〜5.4 — `Where Reviewer backstop を採用する` の条件付き要件。オーケストレータ確定により本 PR 見送り（採用しない経路）。5.4「採用しない場合は既存 3 カテゴリ挙動を変更しない」を満たす（reviewer.md は diff に含まれず不変）。条件付き要件のため未カバーに当たらない
- NFR 1.1〜1.5 — env var 名 / ラベル / exit code / ログ書式 / round 契約の後方互換。`stage-a-verify.sh` 差分は追加コメント 2 箇所のみで非コメントコード変更ゼロを diff で機械確認。挙動不変
- NFR 2.1 / 2.2 — README 後始末節（撤去前提条件 / リポジトリ外オペレータ作業）で記載
- NFR 3.1 / 3.2 — Reviewer 判定境界の不変性。reviewer.md / 判定ルール変更なし
- NFR 4.1 / 4.2 — test ケース 2（冪等 2 回目）で rc=1 を再確認 / resolve 冒頭の source 初期化により前回残値非依存

## Findings

なし

## Summary

design.md / tasks.md 不在の design-less impl ルートで、本件は「design-less は SKIP」を意図仕様として明文化する文書中心の変更。`stage-a-verify.sh` の差分はコメントのみ（非コメントコード変更ゼロを diff で確認）で挙動・ログ書式・exit code・env var 名・round 契約を一切変えず後方互換を維持。Req 1〜4 / NFR 1〜4 の全 numeric ID が README / 各 rule の追記・既存挙動・回帰テストでカバーされ、Req 5 は条件付き（見送り）で破綻なし。`test-design-less-skip.sh` を独立再実行し PASS=4 FAIL=0 を確認。AC 未カバー / missing test / boundary 逸脱のいずれも検出されない。

RESULT: approve
