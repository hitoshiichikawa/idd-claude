# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-05T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-289-impl-docs-per-task-implementer-failed-error-m
- HEAD commit: 8cb1fe75e71170a5bc1db423b70179aeb277dad6
- Compared to: main..HEAD
- Mode: design-less impl（tasks.md 不在）。`_Boundary:_` 制約は存在しないため boundary 観点は AC とドキュメント整合のみで判定。
- Feature Flag Protocol: 対象 repo の CLAUDE.md に `## Feature Flag Protocol` 節は存在せず（line 203 の表参照のみ）→ opt-out として解釈し flag 観点の細目は適用しない。

## Verified Requirements

- 1.1 — README L5476 `### per-task-implementer-failed / error_max_turns 対応` 見出しに両キーワードを含む
- 1.2 — README L5482〜L5618 で「症状」「原因」「診断手順」「対応の優先順位」「ラベルの意味と次アクション」「復旧手順」の 6 観点を網羅
- 1.3 — README L5493〜L5497「`error_max_turns` は許容 turn 上限到達による exit であり必ずしも実テスト失敗を意味しない」明示
- 1.4 — README L5567〜L5573 ラベル意味表に 3 種のラベル意味と次アクションを併記
- 1.5 — QUICK-HOWTO L269〜L290 に最頻出ケース要約と README への詳細リンク、L300 にも次に読む案内を追加
- 2.1 — README L5511〜L5517 診断表で `error_max_turns` と 529 過負荷を観測可能シグナルで区別
- 2.2 — 同表で「Vitest/Jest/pytest fail 出力」「`RESULT: reject`」を実テスト失敗のシグナルとして列挙
- 2.3 — 同表で 529 過負荷時は「再 pickup で回復し得る」と案内
- 2.4 — 同表で実テスト失敗時は「手動仕上げ または Reviewer / Debugger 経路」と案内
- 2.5 — README L5519〜L5520 で `error_max_turns` シグナル時は対応の優先順位節を参照する旨を接続
- 3.1 — README L5523〜L5562 で「(1) タスク粒度の是正 → (2) `DEV_MAX_TURNS` 一時引き上げ → (3) 手動仕上げ」を 3 段階で明示
- 3.2 — README L5527〜L5532 で親タスク細分化 + 「UI = 1 component + 1 test = 1 task」分割指針を含む
- 3.3 — README L5536〜L5547 で「一時的・その場限り」位置付けと「cron 恒久書き換えは非推奨」を明示
- 3.4 — README L5551〜L5556 で手動仕上げを最終手段とし、判断基準（連続 2 回失敗 / 1.5〜2 倍引き上げ後も通過しない）を明示
- 3.5 — README L5559〜L5565 表で各優先順位の次回 watcher 実行への影響を運用者目線で記述
- 4.1 — README L5582〜L5594「A. impl PR がまだ存在しないケース」で `claude-failed` 除去手順を gh コマンドで記述
- 4.2 — README L5596〜L5611「B. impl PR が既に存在するケース」で `ready-for-review` 先付与 → `claude-failed` 後除去の順序を gh コマンドで明示
- 4.3 — README L5577〜L5580 警告 blockquote で順序誤りによる破壊事象（想定外 commit / force-with-lease push）と回避策を記載
- 4.4 — README L5588〜L5594 / L5605〜L5611 で復旧後の期待ラベル状態と次アクションを A / B 各ケースで明示
- 4.5 — README L5613〜L5615 で「運用者の操作として記述、watcher 内部の関数名・コードパスには踏み込まない」と明示
- 5.1 — README L4772 env 表に `DEV_MAX_TURNS` 項目（既定 60、意味、推奨レンジ感）追加
- 5.2 — 同項目に「多い場合はタスクが大きすぎる兆候。恒久引き上げより粒度是正を優先」を推奨欄に記載
- 5.3 — 同項目を既存 `PER_TASK_LOOP_ENABLED` / `PER_TASK_MAX_TASKS` と同じ 4 列表形式（変数 / デフォルト / 推奨 / 用途）で整合（`PR_ITERATION_MAX_TURNS` と同じテーブル設計）
- 5.4 — 同項目で「値変更は次回 watcher 起動時から有効、cron / launchd の再登録不要」「per-task ループの 1 タスクあたり Claude 実行 turn 数上限。Issue 全体ではなくタスク単位で各 fresh session に適用」を明示
- 5.5 — `local-watcher/bin/issue-watcher.sh:512` の `DEV_MAX_TURNS="${DEV_MAX_TURNS:-60}"` は本 PR で変更なし（diff にコード変更なし）
- 6.1 — `tasks-generation.md`（両系統）「fresh session 仕様（前提）」配下で「タスクごとに新規 Claude session で起動」「turn カウンタも各タスクで 0 から始まる」明示
- 6.2 — 同節で「`error_max_turns` で失敗したタスクは再試行時も同一タスク内で再び 0 turn から開始」明示
- 6.3 — README L5503〜L5506 blockquote で fresh session 含意（Issue 全体の turn 枠を増やす発想が無効）を要約
- 7.1 — `tasks-generation.md`（両系統）「粒度指針（推奨）」配下で「1 タスクは `DEV_MAX_TURNS`（既定 60）以内に収まる粒度を目安とする」明示
- 7.2 — 同節で frontend / UI / テスト重めの分割指針（「UI = 1 component + 1 test = 1 task」）を含む
- 7.3 — 同節「既存ガイドラインとの関係」で「3〜10 件目安」「checkbox 必須化」との非矛盾（補助として機能）を明示
- 7.4 — 同節「強度（推奨どまり / Mechanical Check 不在）」で reject 条件としては宣言しないことを明示
- 7.5 — 同節 blockquote で「設計段階で 1 タスクの turn 予算を意識することが、運用時の `error_max_turns` 発生確率を直接下げる最も効果の高い手段」と根拠を記載
- 8.1 — git diff main..HEAD で `DEV_MAX_TURNS` / `PR_ITERATION_MAX_TURNS` / `DEV_MODEL` 等の env 名・既定値・意味は変更なし（README env 表は項目追加のみ）
- 8.2 — `claude-failed` / `per-task-implementer-failed` / `ready-for-review` の付与契約 / 遷移意味の変更なし（Troubleshooting 節での説明追加のみ）
- 8.3 — `local-watcher/bin/*.sh` / `.claude/agents/*.md` 等の watcher / agent 実装コードは git diff に含まれず変更なし
- 8.4 — `tasks-generation.md` の既存規約（checkbox 必須化 / Budget overflow check / 構造化 verify ブロック）は削除・改変なし、新節を末尾追記のみ（diff で確認）
- 8.5 — `diff -r .claude/rules repo-template/.claude/rules` exit 0（byte 一致）確認済み
- NFR 1.1 — 既存 h2 `## トラブルシューティング` 配下に h3 として追加、既存セクションの一意性を維持
- NFR 1.2 — 日本語ベース記述（env 名・ラベル名・コマンド名等の英語固定語彙は除く）
- NFR 1.3 — 既存 `PER_TASK_*` の表と同じ 4 列形式・記述スタイルで整合
- NFR 2.1 — `## トラブルシューティング` 配下の h3 として目次から 2 ホップ以内に到達
- NFR 2.2 — QUICK-HOWTO L289〜L290 が README 詳細節への直接リンク、README L13 が QUICK-HOWTO への top-level リンクで双方向相互リンク成立
- NFR 2.3 — 見出しと本文に `per-task-implementer-failed` / `error_max_turns` / `claude-failed` を含めテキスト検索で発見可能
- NFR 3.1 — 復旧手順 B（README L5599〜L5611）で `ready-for-review` 先付与 → `claude-failed` 後除去のラベル順序を bash コマンド列で明示
- NFR 3.2 — README L5577〜L5580 で順序誤りリスクを `> ⚠️ **警告**` blockquote として手順本文と視覚的に区別して記載

## Findings

なし

## Summary

ドキュメント追加のみで完結する本 spec について、Req 1〜8 と NFR 1〜3 のすべての numeric ID に
対する記述が README / QUICK-HOWTO / `.claude/rules/tasks-generation.md`（root + repo-template
byte 一致）に確認できた。既存 env / ラベル / watcher 実装 / 既存規約は無改変で、後方互換性
（Req 8 / NFR 1.1）も保持されている。tasks.md 不在の design-less impl のため `_Boundary:_`
制約は適用対象外、Feature Flag Protocol は opt-out 解釈で flag 観点も適用外。

RESULT: approve
