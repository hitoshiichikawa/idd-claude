# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-379-impl-feat-watcher-claude-picked-up-issue-reap
- HEAD commit: d87925cd96feb9036116f551d1d2c23d62f74f5e
- Compared to: main..HEAD（full-spec review / ROUND=1）
- Commit count: 21 commits（task 1〜7 の feat + docs(impl-notes) + docs(tasks) + docs(readme)）
- Diff stats: 8 files changed, 3150 insertions(+), 8 deletions(-)
  - 主要追加: `local-watcher/bin/modules/stale-pickup-reaper.sh`(+783) /
    `local-watcher/test/stale_pickup_reaper_test.sh`(+1851) / `README.md`(+153) /
    `local-watcher/bin/issue-watcher.sh`(+72) / `local-watcher/bin/modules/core_utils.sh`(+14) /
    `CLAUDE.md`(+1) / `docs/specs/379-*/impl-notes.md` / `docs/specs/379-*/tasks.md`

## Verified Requirements

### Req 1 起動制御
- 1.1 — `sr_is_enabled` が `STALE_PICKUP_REAPER_ENABLED=true` 厳密一致で rc=0
  （`stale-pickup-reaper.sh` Gate Layer / Section 1 / Section 14c）
- 1.2 — 未設定 / `true` 以外で rc=1（`sr_is_enabled` の `|| return 1` /
  Section 1 / Section 13a, 13b）
- 1.3 — Config ブロック `case ... esac` で `true` 以外をすべて `false` に正規化
  （`issue-watcher.sh:608+` / Section 0）
- 1.4 — gate OFF で `process_stale_pickup_reaper` が即 return 0 + gh stub 0 回
  （Section 13a, 13b / Section 14c）

### Req 2 復旧対象の選定
- 2.1 — クエリ 1 `label:"$LABEL_PICKED"` 発行（`sr_fetch_candidates` / Section 7a）
- 2.2 — クエリ 2 `label:"$LABEL_CLAIMED"` 発行 + jq `unique_by(.number)` で結合
  （Section 7a）
- 2.3 — `-label:"needs-decisions"` / `-label:"awaiting-design-review"` /
  `-label:"needs-quota-wait"` / `-label:"blocked"` / `-label:"hold"` /
  `-label:"staged-for-release"` を `exclude_filter` に含む（Section 7a）
- 2.4 — `-label:"$LABEL_FAILED"` を `exclude_filter` に含む（Section 7a）
- 2.5 — server-side `gh --search` filter のみ使用（client-side filter なし。
  実装で確認）

### Req 3 アクティブセッション判定（誤検出防止）
- 3.1 — `sr_is_active` が `age == 0 && lock == 0 && sess == 0` の AND で inactive
  確定（Section 11 で 2^3=8 通り組み合わせ assert）
- 3.2 — いずれか 1 観点でも non-0（active 可能性あり）なら return 0 で keep
  （Section 11 の 7 ケース）
- 3.3 — Active Decision Layer は read-only（`gh` / `git` を呼ばない / 実装の
  Active Decision Layer 全関数で確認 / Req 6.3 と整合）
- 3.4 — `first_seen_at` 不在 / date parse 失敗 / fuser+lsof 不在 / flock 不在で
  safe-side fallback（Section 8d, 8e, 8f / 10d, 10e / 11 の lock=2 ケース）
- 3.5 — `sr_log "issue=#$id ... age=$age lock=$lock sess=$sess"` を `sr_is_active`
  内で 1 行記録（Section 11 で log 形式 grep assert）

### Req 4 閾値
- 4.1 — `STALE_PICKUP_REAPER_THRESHOLD_MINUTES` env、既定 45（Config ブロック /
  Section 0）
- 4.2 — `sr_check_marker_age` が閾値未満で rc=1 → `sr_is_active` で keep
  （Section 8a）
- 4.3 — Config `case ''|*[!0-9]*) ...=45 ;;` + `-le 0 → 45` 正規化（Section 0）
- 4.4 — 有効整数で `-ge "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES"` 判定
  （Section 8g で 10 分閾値で動的反映を確認）

### Req 5 復旧アクションと状態遷移
- 5.1 — `gh issue edit ... --remove-label "$LABEL_PICKED"`（Section 12a）
- 5.2 — 同一 PATCH 内で `--remove-label "$LABEL_CLAIMED"`（Section 12a）
- 5.3 — `gh issue view ... --json labels` で auto-dev 残存確認、欠落時のみ
  `--add-label "$LABEL_TRIGGER"`（Section 12a + 12c）
- 5.4 — `sr_log "issue=#$issue reverted reason=stale-pickup orphan
  age=${age_minutes}m prev_labels=$prev_labels_csv"`（Section 12a）
- 5.5 — `SR_PROCESSED_THIS_CYCLE` in-memory set + marker `status=reverted` で
  冪等化（Section 12b + 13e）
- 5.6 — 1 回目 PATCH 失敗時 `sr_warn` + return 1（marker は observing のまま
  温存 / Section 12e + 13f）

### Req 6 branch 不在時の扱い
- 6.1 — `sr_revert_to_auto_dev` は `git` を呼ばない（branch 状態によらず継続 /
  Recovery Action Layer 実装で確認）
- 6.2 — 同上（branch 温存 / `git` 参照ゼロ）
- 6.3 — Active Decision Layer も `git` 参照ゼロで branch を判定根拠にしない

### NFR
- NFR 1.1 — 既存 env 名（`REPO` / `REPO_DIR` / `LOG_DIR` 等）に変更なし。
  新規 `STALE_PICKUP_REAPER_*` 5 件のみ追加
- NFR 1.2 — 既存ラベル名・付与契約を変更なし（既存 `LABEL_*` 定数のみ参照、
  新ラベル定数追加なし）
- NFR 1.3 — gate OFF で gh stub 0 回 + rc=0 を Section 13a/13b/14c で構造的検証
- NFR 2.1 — `SR_PROCESSED_THIS_CYCLE` で同サイクル内重複起動防止
  （Section 12b + 13e）
- NFR 2.2 — JSON marker による永続化（observing → reverted 状態継承）
- NFR 2.3 — `$HOME/.issue-watcher/stale-pickup/$REPO_SLUG/` 配下に配置、
  mktemp + mv -f atomic write（Section 4 / Section 5）
- NFR 3.1 — Issue 番号 `^[0-9]+$` 検証（Section 12d で 5 ケース reject 確認）/
  jq `--arg` / `--argjson`（Section 6）/ gh の `--` でオプション解釈打ち切り
- NFR 3.2 — secrets を Issue コメント・ログに出さない（実装で `GH_TOKEN` 等の
  出力ゼロ確認）
- NFR 4.1 — `sr_log` で 1 行ログ記録（Section 11 / 12a / 13）
- NFR 4.2 — `sr_is_active` の keep 経路で `age=N lock=N sess=N` を 1 行記録
  （Section 11）
- NFR 5.1 — `shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh
  local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh`
  警告ゼロ（reviewer 再実行で EXIT=0 確認）/ `bash -n local-watcher/bin/issue-watcher.sh`
  エラーなし（EXIT=0 確認）
- NFR 5.2 — `bash local-watcher/test/stale_pickup_reaper_test.sh` を reviewer 側で
  再実行し **193 assertions PASS / EXIT=0** を確認（impl-notes 記載と一致）
- NFR 6.1 — `diff -r .claude/agents repo-template/.claude/agents` 空 + `diff -r
  .claude/rules repo-template/.claude/rules` 空（reviewer 再実行で EXIT=0 確認）。
  本 spec で `.claude/{agents,rules}` の編集なし

## Boundary 確認

tasks.md 各 task の `_Boundary:_` で許可されたファイルのみ変更されていることを
確認した:

| 変更ファイル | 該当 task の Boundary |
|---|---|
| `local-watcher/bin/modules/stale-pickup-reaper.sh` | tasks 2-5: stale-pickup-reaper.sh ✓ |
| `local-watcher/bin/modules/core_utils.sh` | task 1: core_utils.sh (Logger) ✓ |
| `local-watcher/bin/issue-watcher.sh` | task 1, 6: Config + REQUIRED_MODULES + call site ✓ |
| `local-watcher/test/stale_pickup_reaper_test.sh` | 各 task の同タスク内テスト規約 ✓ |
| `README.md` | task 7: README.md ✓ |
| `CLAUDE.md` | task 7: CLAUDE.md ✓ |
| `docs/specs/379-*/{tasks.md,impl-notes.md}` | spec 内補助（impl-notes 規約） ✓ |

境界逸脱なし。

## Findings

なし

## Summary

要件定義 (Req 1.1〜6.3 / NFR 1.1〜6.1) のすべてが実装または近接テストでカバーされ、
tasks.md の `_Boundary:_` 違反もない。reviewer 側で `shellcheck` / `bash -n` /
`stale_pickup_reaper_test.sh` (193 assertions PASS) / `diff -r .claude/{agents,rules}
repo-template/.claude/{agents,rules}` を再実行し、すべて green であることを確認した。
opt-in gate（既定 false）+ 二重防御 + 構造的検証で本機能導入前と完全に等価な後方互換性も
担保されている。

RESULT: approve
