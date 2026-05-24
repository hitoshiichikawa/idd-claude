# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-191-impl-bug-watcher-open-design-pr-issue-dispatc
- HEAD commit: fe9f0eaecb87a606e7fcccb57a4eef6ab37b70db
- Compared to: main..HEAD

変更ファイル: `local-watcher/bin/issue-watcher.sh`（新ガード `check_open_design_pr` 追加 +
candidate ループへの呼び出し挿入）/ `README.md`（暫定運用ガイド追記）。Architect 非起動の
bug fix のため `tasks.md` / `design.md` は不在（impl-notes.md に明記）。`requirements.md` を
正本に AC を 1 件ずつ突合した。CLAUDE.md に `## Feature Flag Protocol` 節は存在しないため
opt-out 扱いとし、flag 観点は適用しない。

## Verified Requirements

- 1.1 — `check_open_design_pr` が open design PR 検出時に `reason=open-design-pr-exists` で
  return 1 → `_dispatcher_run` candidate ループ（issue-watcher.sh:11553-11556）で `continue`
  し当該サイクルを skip。
- 1.2 — ガードはラベル状態を一切参照せず head ref のみで判定（issue-watcher.sh:10043-10052）。
  ラベルベース除外より後段の claim 直前で必ず評価されるため保護ラベル不在でも design 再実行を
  起動しない。
- 1.3 — `gh pr list --state open`（issue-watcher.sh:10021）で server-side 絞り込み。CLOSED/MERGED
  のみのケースは候補に到達せず `reason=no-open-design-pr` で return 0（continue）。
- 1.4 — GraphQL linked field ではなく `gh pr list --search "is:pr is:open
  claude/issue-<N>-design- in:head"`（issue-watcher.sh:10023）の head ref ベース検出。linked
  非依存。既存 `drr_find_merged_design_pr`（#40/#80, issue-watcher.sh:5184）と同方式。
- 1.5 — jq `startswith("claude/issue-<N>-design-")` strict prefix（issue-watcher.sh:10043-10049）。
  既存 #80 の strict 化と同一ロジック。impl-notes の境界スモークで #19 が #191 を誤検出しないこと、
  複数 open は PR 番号最大採用、null head 防御を確認。
- 2.1 — 既存 candidate query / ラベル除外ロジックを変更せず新ガードを追加挿入のみ（diff は純粋な
  insertion で既存行の改変なし）。
- 2.2 — ガードはラベル状態に依存せず head ref のみで判定するため、保護ラベルが外れた Issue でも
  open design PR 単体で抑止。
- 3.1 — `gh pr list` 非ゼロ終了 → `reason=design-pr-probe-failed` で return 1（skip）。jq parse 失敗
  → `reason=design-pr-probe-jq-parse-error` で return 1。入力 Issue 番号が空/非数値 →
  `reason=invalid-issue-number-design-guard` で return 1。
- 3.2 — `timeout "${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}"` でラップ（issue-watcher.sh:10020）。
  rate-limit 検知時は `reason=design-pr-probe-rate-limited` で return 1（skip）。
- 4.1 — `pclp_log "skip issue=#<N> pr=#<P> reason=open-design-pr-exists"`（issue-watcher.sh:10058）で
  Issue 番号・検出 PR 番号・理由を 1 行記録。
- 4.2 — 既存 `pclp_log`/`pclp_warn`（prefix `pre-claim-probe:`, issue-watcher.sh:9750-9758）の
  `key=value` 形式を使用し既存 Pre-Claim 系ログと同形式。
- 5.1 — ガードは Issue pickup 経路（candidate ループ）にのみ挿入。`needs-iteration` 駆動の PR 反復
  経路には diff で一切変更なし。
- 5.2 — 本ガードは `_dispatcher_run` の candidate ループ内（`check_existing_impl_pr` 直後）に限定
  挿入され、PR 駆動の反復処理経路には作用しない。
- NFR 1.1 — design PR を持たない通常 Issue では候補空 → `reason=no-open-design-pr` で return 0
  （導入前と等価）。境界スモーク（空配列・impl head のみ）で確認。
- NFR 1.2 — 新規 env var を追加せず `DRR_GH_TIMEOUT` を再利用。exit code 意味（0=continue/1=skip）は
  既存 claim 直前ガードと同一。ラベル契約・cron 登録文字列・ログ出力先は不変。
- NFR 1.3 — GitHub API 呼び出しを既存 `DRR_GH_TIMEOUT`（既定 60 秒）でラップ。
- NFR 2.1 — README の Pre-Claim Filter 運用節に「保護ラベルを design PR merge まで外さない」暫定
  運用ガイドを追記（README.md diff で確認）。

## Findings

なし

## Summary

全 numeric requirement ID（1.1-1.5, 2.1-2.2, 3.1-3.2, 4.1-4.2, 5.1-5.2, NFR 1.1-1.3, 2.1）に
対応する実装を issue-watcher.sh / README.md の差分で確認。本リポジトリのテスト規約（unit test
フレームワーク不在、shellcheck + 手動スモークが正本）に従い、impl-notes 記載の jq フィルタ抽出
スモーク（#19 vs #191 境界等）と shellcheck warning 0 件を裏取り（reviewer 側で shellcheck
再実行 exit 0 を確認）。boundary 逸脱・AC 未カバー・missing test いずれも検出せず。

RESULT: approve