# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-09-15T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-536-impl-fix-watcher-github-api-rate-guard-graphq
- HEAD commit: 7f448a9526f2790ab07a6a2e1dac55870259ad57
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/api-rate-guard.sh` / `local-watcher/test/api_rate_guard_degrade_test.sh` / `README.md`（+ spec 配下 requirements.md / impl-notes.md）
- 備考: 本 Issue は design-less impl（tasks.md / design.md 不在）。`_Boundary:_` アノテーションは存在せず、変更ファイルは全て Issue スコープ内。CLAUDE.md に `## Feature Flag Protocol` 節は存在しない（表の 1 行のみ）ため通常の 3 カテゴリ判定を適用。

## Verified Requirements

- 1.1 — `grl_graphql_bucket_refresh` が `gh api graphql -f query='{ rateLimit { limit used remaining resetAt } }'` の `.data.rateLimit.remaining/.limit` を取得（degrade_test test 2: graphql=4800 が GraphQL 由来）
- 1.2 — `grl_buckets_refresh` が REST `gh api rate_limit` の `.resources.core/.search` を読む（test 2: core=4990 / search=30 が REST 由来）
- 1.3 — GraphQL 由来の `GRL_BUCKET_GRAPHQL_REMAINING` を縮退判定・可視化ログ双方で使用（test 7a 統合: 実残量 100 が反映され skip）
- 1.4 — 専用 `rateLimit` クエリで取得し応答ヘッダ流用コードを持たない（仮案 B 不採用 / test 2）
- 2.1 — `grl_degrade_should_run` が graphql 実残量 < 閾値で rc=1 skip（test 6 / test 7a）
- 2.2 — skip 時 WARN に `skip processor=<name> reason=degrade bucket=graphql remaining=<r> threshold=<t>`（test: skip ログ内容検証）
- 2.3 — 残量 >= 閾値で rc=0 実行（test 6: 残量 600）
- 2.4 — gate off で rc=0（test 6: gate off 残量僅少でも skip しない）
- 3.1 — `grl_buckets_log` の graphql 欄に GraphQL 実残量/上限を出力（test 2: graphql=4800/5000）
- 3.2 — core/search 欄は REST 由来（test 2: core=4990/5000 search=28/30）
- 3.3 — 固定書式 `gh-rate-limit: core=r/l graphql=r/l search=r/l` と prefix 不変（test 2）
- 4.1 — rate limit 起因失敗で `GRL_BUCKET_GRAPHQL_STATUS=rate_limited` → 残量 0 とみなし skip（test 4 / 4b / 6 / 7b）
- 4.2 — rate limit skip の WARN に `reason=degrade-graphql-fetch-rate-limited bucket=graphql threshold=`（test: rate limit skip ログ検証）
- 4.3 — rate limit 以外（timeout/parse）失敗で `unavailable` → rc=0 全実行（test 5 / 7c）
- 4.4 — rate limit 以外失敗で WARN 記録（test 5: 「rate limit 以外」WARN）
- 4.5 — 全 refresh 経路が rc=0 でサイクル中断しない（各 test 継続）
- 5.1 — 両 gate off で early return、GraphQL クエリ・REST とも呼ばない（test 1: 呼び出しログ空）
- 5.2 — env var 名 / prefix `gh-rate-limit:` / 固定書式を不変維持（diff 上 env var 追加なし）
- 5.3 — 両 gate off で no-op 維持（test 1）
- 6.1 — gh stub を GraphQL `rateLimit` クエリ経路へ対応（stub に `gh api graphql` 分岐追加）
- 6.2 — 残量 < 閾値の skip を live API なしで検証（test 7a）
- 6.3 — rate limit 起因失敗で縮退発火を検証（test 7b）
- 6.4 — rate limit 以外失敗で全実行フォールバックを検証（test 7c）
- NFR 1.1 — 1 サイクル最大 2 回（冒頭 + 終端）の GraphQL クエリ = 最大 2pt（impl-notes 方針 / 要件許容範囲）
- NFR 2 — 既存 env var / ラベル / exit code / ログ出力先 不変・新規ラベルなし
- NFR 3 — WARN で失敗種別（rate limit 起因 / 以外）を判別可能（test 4/5）
- NFR 4 — `shellcheck` api-rate-guard.sh / degrade_test.sh とも新規警告 0（reviewer 再実行で確認）

## Findings

なし

## Summary

全 numeric ID（Req 1〜6 / NFR 1〜4）に対応する実装とテストが最新差分内に確認できた。degrade 判定を全体 status から graphql status へ移した点は Req 2/4 が全て graphql バケット参照であることと整合しており、boundary 逸脱ではない。reviewer 側で degrade_test（44/44 PASS）・隣接 api-rate-guard テスト群・shellcheck を再実行し全て green を確認した。

RESULT: approve
