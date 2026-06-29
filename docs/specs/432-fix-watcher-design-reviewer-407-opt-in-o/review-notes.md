# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-06-29T10:08:24Z -->

## Reviewed Scope

- Branch: claude/issue-432-impl-fix-watcher-design-reviewer-407-opt-in-o
- HEAD commit: 717d64ec59b43854f8eeaf52396f7e8fdd26b138
- Compared to: main..HEAD
- 変更ファイル: README.md / local-watcher/bin/issue-watcher.sh /
  local-watcher/bin/modules/pr-design-reviewer.sh / 3 test files（1 新規）
- 注記: 本 spec ディレクトリには `requirements.md` のみ存在し、`design.md` / `tasks.md` /
  `impl-notes.md` は不在（default-flip の単純修正で Architect 非起動）。`_Boundary:_` 注釈が
  ないため境界判定は requirements.md の Out of Scope を正本として照合した。

## Verified Requirements

- 1.1 — 未設定 → ON。`DESIGN_REVIEWER_ENABLED="${...:-true}"` + `case false) ... *) true`
  （issue-watcher.sh）。test: `pdr_default_on_test.sh` "unset → true" / `pdr_resolve_gate_test.sh`
- 1.2 — 空文字 → ON。同正規化。test: `pdr_default_on_test.sh` "'' → true"
- 1.3 — `=true` → ON。test: 上記両 test の "true → true"
- 1.4 — `=false` → OFF（追加呼び出し / ログ / status / ラベルゼロ）。`case false) :` +
  `pdr_gate_enabled` 厳密 `=true`。test: `pdr_no_op_test.sh` Case 1（gh/git/claude/log/warn=0）
- 1.5 — `False`/`FALSE`/`0`/`1`/`on`/typo 等 → ON 正規化。test: `pdr_default_on_test.sh` /
  `pdr_resolve_gate_test.sh` の正規化マトリクス
- 1.6 — 起動時に有効/無効を grep 可能なログ化。cycle startup echo に
  `design-reviewer=${DESIGN_REVIEWER_ENABLED}` トークンを追加（issue-watcher.sh:~1564）
- 2.1 — 資産不在時 claude 不起動 + WARN 1 行 + skip。新規 `pdr_prompt_asset_resolvable` +
  `process_pr_design_reviewer` gate 後の no-op return。test: `pdr_no_op_test.sh` Case 3
- 2.2 — skip 時に `claude-review=failure` 非 publish / `needs-iteration` 非付与。no-op は
  候補取得・gh 操作の前で return。test: Case 3（gh 呼び出し 0）
- 2.3 — 後続サイクルでの冪等再試行。no-op は state を書かず head sha marker 不生成のため再試行可能
- 2.4 — dispatcher fail-continue 維持（return 0）。test: Case 3（rc=0）
- 3.1 — `=false` 既存 cron が本変更前と等価 OFF。test: `pdr_no_op_test.sh` Case 1 +
  `pdr_default_on_test.sh` "existing cron with 'false' stays false"
- 3.2 — `=true` 既存 cron が機能的に同一。`pdr_gate_enabled` 厳密 `=true` → ON（挙動不変）
- 3.3 — 他 `DESIGN_REVIEWER_*` env 不変。diff で `DESIGN_REVIEWER_ENABLED` のみ変更を確認
- 3.4 — env 名 / 参照 path / exit code / cron 文字列の解釈不変（既定値のみ反転）
- 3.5 — `needs-iteration` / `claude-review` の意味不変（未変更）
- 3.6 — log prefix 不変（startup echo はトークン追記のみ、pdr_log prefix 未変更）
- 4.1 — README オプション表の既定値を `false`→`true`（opt-out）、正規化規則を更新（README diff）
- 4.2 — 「Design PR Reviewer (#407)」節 + env 表の opt-in 記述を opt-out / 既定 ON へ書換
- 4.3 — migration note（⚠️ 既定反転ブロック）を追加
- 4.4 — opt-out 手順（`DESIGN_REVIEWER_ENABLED=false` 明示）を FAQ / 推奨手順に明示
- 4.5 — issue-watcher.sh 宣言行直上コメントを「既定 ON / `=false` で opt-out」へ書換
- 5.1 — `.claude/agents` の `diff -r` 空を確認（AGENTS IN SYNC）
- 5.2 — `.claude/rules` の `diff -r` 空を確認（RULES IN SYNC）
- 5.3 — 同一 branch で README 更新済み、スクリプトコメントと矛盾なし
- 6.1 — `shellcheck` 警告ゼロを再確認（SHELLCHECK CLEAN）
- 6.2 — `bash -n` 通過を再確認（issue-watcher.sh / pr-design-reviewer.sh とも OK）
- 6.3 — 値正規化の入出力テーブル test `pdr_default_on_test.sh`（新規 / 17 PASS）
- 6.4 — cron-like 最小 PATH（`env -i HOME=$HOME PATH=/usr/bin:/bin`）で未設定時 `resolved=true`
  を再現確認（pure-bash `:-true` で PATH 非依存）
- 6.5 — 正規化は smoke 起動の正常 exit を阻害しない（純パラメータ展開 / 副作用なし）
- NFR 1.1/1.2 — `=false` 明示時の追加呼び出し・ログ・ラベル・status ゼロ（Case 1）、
  env 名 / ラベル / status / exit code / log prefix 不変
- NFR 2.1/2.2 — 有効時 grep 可能な startup ログ、per-PR ログ増加は WARN 経路のみで 10 行以下
- NFR 4.1/4.2 — claude 起動は設計 PR head pattern + 未処理 sha に限定（`pdr_classify_design_pr`
  / `DESIGN_REVIEWER_MAX_PRS` 未変更）

## Findings

なし

## Summary

`DESIGN_REVIEWER_ENABLED` の既定反転（opt-in/OFF → opt-out/ON）と graceful no-op 安全弁が
全 numeric AC をカバー。新規・更新テスト（17/16/16 PASS）、shellcheck clean、bash -n OK、
agents/rules の diff -r 空、最小 PATH 既定 ON を再確認。Out of Scope の他 env 既定・codex
スキップ挙動・判定基準・repo-template への波及はなく境界逸脱なし。

RESULT: approve
