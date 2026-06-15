# 実装ノート: Issue #346 `feat(watcher): blocked unblock スイープ`

## 実装方針サマリ

- 配置: `local-watcher/bin/issue-watcher.sh` 本体に inline で `dr_unblock_*` 関数群を追加（既存 `dr_*` namespace を継続。新 module は作らない）
- opt-in env var: **`DEP_AUTO_UNBLOCK_ENABLED`**（既定 OFF。正規化規則は `=true` 厳密一致のみ有効、それ以外は OFF）
- 起動位置: `_dispatcher_run` のメイン候補クエリ（`gh issue list` 2 回）より **前段**で `dr_unblock_sweep` を 1 度呼ぶ
- gate OFF の場合は冒頭 1 行 if で即 return（gh API ゼロ呼び出しを保証 / NFR 2.1）
- 自動解除コメントマーカー: `<!-- idd-claude:dep-unblock-cleared:v1 -->`（監査識別用）
- 空依存マーカー通知コメントマーカー: `<!-- idd-claude:dep-unblock-orphan-marker:v1 -->`（冪等性判定キー）
- gate ON 時の `dr_apply_block` エスカレーションコメント文面分岐: `dr_unblock_gate_enabled` 関数 1 つに集約

## 確定事項

| 項目 | 値 | 根拠 |
|---|---|---|
| opt-in env var 名 | `DEP_AUTO_UNBLOCK_ENABLED` | requirements.md Open Questions の候補名。既存 `*_ENABLED` 命名と整合 |
| 既定値 | 未設定 = OFF | NFR 1 後方互換 |
| 正規化 | `=true` のみ ON、それ以外は OFF | `MERGE_QUEUE_ENABLED` / `PROMOTE_PIPELINE_ENABLED` と同パターン |
| 自動解除コメントマーカー | `<!-- idd-claude:dep-unblock-cleared:v1 -->` | 監査識別用 |
| 空依存通知コメントマーカー | `<!-- idd-claude:dep-unblock-orphan-marker:v1 -->` | 冪等性判定キー |
| スイープ起動位置 | `_dispatcher_run` 先頭（候補クエリより前） | Req 2.3 |
| 配布範囲 | `local-watcher/bin/issue-watcher.sh` + README のみ | Req 9.1 |

## 関数一覧

| 関数 | 責務 |
|---|---|
| `dr_unblock_gate_enabled` | env var 正規化後の真偽判定（gate ON 時 0、OFF 時 1） |
| `dr_unblock_has_orphan_marker` | 当該 Issue の過去コメントに空依存通知マーカーが既にあるか判定 |
| `dr_unblock_post_unblocked_comment` | 自動解除コメント本文生成 + 投稿 |
| `dr_unblock_post_orphan_marker_comment` | 空依存通知コメント本文生成 + 投稿 |
| `dr_unblock_resolve_one_issue` | 1 Issue を対象に依存全解決判定 → 解除 / 通知 / 維持の分岐 |
| `dr_unblock_sweep` | 対象 Issue 列挙（`gh issue list --label auto-dev --label blocked`）→ 各 Issue に `dr_unblock_resolve_one_issue` を適用。冒頭で gate 判定 |

## テスト戦略

`local-watcher/test/dr_unblock_sweep_test.sh` を新規追加。既存 `po_apply_awaiting_slot_test.sh` の `extract_function` + `gh` stub イディオムを踏襲。

| AT-ID | 検証ケース | カバー関数 |
|---|---|---|
| AT-a | 全依存 resolved + gate ON → 除去 + 解除コメント | `dr_unblock_resolve_one_issue` |
| AT-b | 1 件以上 unresolved + gate ON → 何もしない | `dr_unblock_resolve_one_issue` |
| AT-c | gate OFF（未設定 / `false` / typo）→ gh ゼロ呼び出し | `dr_unblock_sweep` + `dr_unblock_gate_enabled` |
| AT-d | 空依存 + 未通知 + gate ON → orphan marker 1 件 | `dr_unblock_resolve_one_issue` |
| AT-e | 空依存 + 通知済 + gate ON → コメント投稿なし | `dr_unblock_has_orphan_marker` |
| AT-f | 連続 2 回スイープ → 累積なし | end-to-end（同一 fixture を 2 回流す） |
| AT-g | ラベル除去成功 + コメント投稿失敗 → `dr_warn` 1 行 + 次 Issue へ | `dr_unblock_resolve_one_issue` |
| AT-h | エスカレーションコメント文面分岐 | `dr_apply_block` を抽出して文面 grep |

## トレードオフ

- 自動解除コメントの本文に「resolved 依存の列挙」までは含めず、「全依存解決」と要約する（requirements.md Open Questions で Developer 裁量とされている範囲。実装複雑度・comment 過剰肥大化トレードオフで要約方針を採用。必要なら詳細は構造化ログから追える / Req 7）
- 通知マーカーの冪等性検証は `gh issue view --json comments` で過去コメント本文を一括取得し in-bash で grep する（NFR 2.2 範囲内: 1 Issue あたり read API は依存件数 + 1（コメント取得）に収まる。空依存ケースは依存件数ゼロなので read 1 のみ）
- gh API write 失敗時のロールバックは行わず警告ログのみ（既存 `dr_apply_block` の寛容方針と整合 / NFR 3.2）

## 確認事項

- 自動解除コメント文面の tone・厳密文言は Developer 裁量で確定（requirements.md Open Questions）。後続レビューで「resolved 依存の列挙」を含めるべきとの判断が出た場合は別 Issue で拡張する想定

## AC トレース

| Requirement | 担保テスト / 実装位置 |
|---|---|
| Req 1.1 | AT-a / `dr_unblock_sweep` 冒頭 gate check |
| Req 1.2 | AT-c |
| Req 1.3 | AT-c（typo: `tRuE` / `1` / `on` を OFF として扱う） |
| Req 1.4 | 全テスト（既存 env var / ラベル / exit code に触れない） |
| Req 2.1 | AT-a / `dr_unblock_sweep` の `gh issue list --label auto-dev --label blocked` |
| Req 2.2 | `gh issue list` の状態指定 `--state open` + 既存除外（`claude-failed` 等は label 自体を `add-label` していないため `auto-dev` AND `blocked` の AND クエリから自然と外れる。明示除外もコード上で実施） |
| Req 2.3 | `dr_unblock_sweep` を `_dispatcher_run` 冒頭で呼ぶ |
| Req 3.1 | AT-a / `dr_unblock_resolve_one_issue` の全件 resolved 分岐 |
| Req 3.2 | AT-a / `dr_unblock_post_unblocked_comment` |
| Req 3.3 | 解除コメント本文に「依存全解決による自動解除」相当の文を含める |
| Req 3.4 | AT-g + 「ラベル除去失敗時はコメント投稿せず skip」分岐 |
| Req 4.1 | AT-b |
| Req 4.2 | `dr_resolve_one` 未知 verdict は内部 case 文で `unresolved` 扱い |
| Req 4.3 | 既存実装に従う（再投稿は `dr_apply_block` 冪等性ガードで防止 / `dr_unblock_*` ではエスカレーションコメント自体を作らない） |
| Req 5.1 | AT-d, AT-e |
| Req 5.2 | AT-d |
| Req 5.3 | AT-e |
| Req 5.4 | マーカー文字列 `<!-- idd-claude:dep-unblock-orphan-marker:v1 -->` |
| Req 6.1 | AT-f |
| Req 6.2 | AT-b, AT-e |
| Req 6.3 | 解除条件未充足時は `gh issue edit` / `gh issue comment` を呼ばない |
| Req 7.1〜7.4 | 各分岐で `dr_log` / `dr_warn` を 1 行ずつ呼ぶ |
| Req 8.1〜8.2 | AT-h / `dr_apply_block` の文面分岐 |
| Req 9.1 | local-watcher のみに変更を限定（diff で `repo-template/` 配下が空） |
| Req 9.2 | README.md 同一コミットで更新 |
| NFR 1.1 | AT-c（gate OFF 時の gh API ゼロ呼び出し） |
| NFR 1.2 | `dr_*` 既存関数群 signature 不変（dr_check_dependencies / dr_apply_block の戻り値契約は不変、文面のみ分岐） |
| NFR 2.1 | AT-c |
| NFR 2.2 | 各 Issue あたり API 呼び出しを上限内に抑える（依存件数 + ラベル除去 1 + コメント 1） |
| NFR 3.1 | `dr_resolve_one` が `api error` を返したら unresolved 扱い（既存挙動を流用） |
| NFR 3.2 | AT-g |
| NFR 4.1 | 構造化ログ `dr: issue=#N verdict=...` 形式 |
| NFR 4.2 | 解除コメント本文に「watcher による自動解除」が読み取れる文言 |
| NFR 5.1 | AT-f |

## テスト結果サマリ

- 新規追加: `local-watcher/test/dr_unblock_sweep_test.sh` — PASS=51 / FAIL=0
- 既存テスト（24 ファイル）回帰なし: 全 PASS
- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/test/dr_unblock_sweep_test.sh install.sh setup.sh .github/scripts/*.sh` 警告ゼロ
- `bash -n local-watcher/bin/issue-watcher.sh` 構文 OK
- `diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules repo-template/.claude/rules` 差分なし（同期維持）

## 残課題

- 本機能は OFF 既定の opt-in 制で配布される。self-hosting で有効化したい場合は cron 設定に
  `DEP_AUTO_UNBLOCK_ENABLED=true` を追加する必要がある（運用者判断）
- 自動解除コメントの文面 tone・解除サマリの詳細度（resolved 依存の列挙）は今回最小限にした。
  実運用で「resolved 依存を明示してほしい」と判断された場合は別 Issue で拡張する
- E2E スモークテスト（実際の cron tick + 実 GitHub Issue）は人間運用者の側で行う想定。
  単体テスト（gh stub）でカバーしたケースは AT-a〜AT-h の 8 ケース + 補助 8 ケース

STATUS: complete

