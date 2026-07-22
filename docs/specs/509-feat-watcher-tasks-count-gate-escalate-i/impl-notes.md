# 実装ノート: #509 tasks-count-gate escalate 時の子 Issue 分割案コメント

## 実装方針の要約

- 実装先は既存 module `local-watcher/bin/modules/tasks-count-gate.sh`（prefix `tc_` 維持 / 新 module なし）。
  393 行 → 966 行で family 分割閾値（1,200 行）には未到達。
- opt-in gate `TC_SPLIT_PROPOSAL_ENABLED`（既定 `false` / リテラル `true` 厳密一致のみ有効）を
  `watcher-config.sh` に追加。`TC_ENABLED` / `MODEL_ROUTING_ENABLED` とは独立。
- **純粋関数と副作用関数を分離**: 抽出 / グルーピング / 本文生成は GitHub API を触らない純粋関数、
  投稿系のみ副作用（`tc_post_split_proposal_comment` / `tc_split_proposal_already_posted`）。
- LLM 追加起動なし（bash の文字列処理のみ / NFR 3.1）。escalate 1 件あたりの追加 API 呼び出しは
  既投稿確認 1 回 + 投稿 1 回の計 2 回（NFR 3.2）、gate OFF 時は 0 回 + ログ 0 行（NFR 3.3 / 1.4）。
- 既存 escalate 処理の**後ろに追加**する形で呼び出し（`tc_run_post_architect_check` の escalate 分岐、
  `|| true` 付き）。生成・投稿の失敗は WARN のみで rc=0（fail-open / Req 6.5, 6.6）。

### 追加関数（`local-watcher/bin/modules/tasks-count-gate.sh`）

| 関数 | 種別 | 役割 |
|---|---|---|
| `tc_split_proposal_enabled` | 純粋 | gate 判定（`true` 厳密一致） |
| `tc_sanitize_text` | 純粋 | 未信頼 tasks.md 断片の無害化 |
| `tc_truncate_title` | 純粋 | タイトル案 120 文字上限 |
| `tc_extract_top_level_tasks` | 純粋（read） | 最上位・未完了タスク + `_Depends:_` 正規化 |
| `tc_group_tasks` | 純粋 | 相互到達（SCC）併合によるグルーピング |
| `tc_build_split_proposal_body` | 純粋（read） | コメント本文生成（rc: 0 / 1 失敗 / 2 タスク 0 件） |
| `tc_split_proposal_already_posted` | 副作用 | 専用マーカーによる冪等判定（gh view 1 回） |
| `tc_post_split_proposal_comment` | 副作用 | gate → 生成 → 冪等 → 投稿の orchestrator |

## AC トレーサビリティ

| 要件 | 実現箇所 / 検証テスト |
|---|---|
| Req 1.1〜1.6（gate / 既定無効 / 独立性） | `tc_split_proposal_enabled` + config。Case E1〜E5（無効値 7 種 / 未設定 / API 0 回 / ログ 0 行） |
| Req 2.1〜2.3（escalate のみ / 既存を置換しない） | `tc_run_post_architect_check` escalate 分岐。Case E6〜E9 |
| Req 2.4（タスク 0 件） | `tc_build_split_proposal_body` rc=2 → skip ログ。Case D1〜D3 |
| Req 2.5（同一 tasks.md を入力） | 呼び出し元が計数と同じ `$tasks_path` を渡す。Case E7 |
| Req 2.6（design 経由しない経路） | hook が design 分岐内側のみ（既存構造 / 追加変更なし） |
| Req 3.1〜3.3（構成単位 / 子・完了除外 / 計数一致） | `tc_extract_top_level_tasks`（正準 regex 一致）。Case A1〜A3, B1, B2, B5 |
| Req 3.4, 3.5（循環併合 / 子 ID 正規化） | `tc_group_tasks` + 抽出時の正規化。Case C1〜C3, C5 |
| Req 3.6, 3.7（網羅性 / 決定論性） | グルーピングの構成上保証。Case A4, A19, C7 |
| Req 4.1〜4.4, 4.11（タイトル / ID / Split from / Parent / 件数・閾値） | 本文生成。Case A5〜A8, A13, A14 |
| Req 4.5, 4.6（案間依存 / 案番号の置換注意） | `Depends on: 案 N` + 本文注記。Case C6, A17 |
| Req 4.7, 4.8（canonical 記法 / `Blocks:` 非出力） | 本文テンプレ。Case A9, A10 |
| Req 4.9, 4.10（提案のみ / 起票コマンド雛形） | 本文テンプレ。Case A11, A12, H5 |
| Req 5.1〜5.7（冪等） | `tc_split_proposal_already_posted`（専用マーカー）。Case A15, A16, F1〜F4 |
| Req 6.1〜6.4（既存挙動不変） | 既存関数・マーカー文字列・閾値は未変更。Case E6, A16 |
| Req 6.5, 6.6, 6.9（fail-open / silent fail 禁止） | WARN + rc=0。Case G3〜G7 |
| Req 6.7（tasks.md 非改変） | read のみ。Case J1 |
| Req 6.8（exit code 不変） | 呼び出しは `|| true`、関数は常に rc=0 |
| Req 7.1〜7.5（README） | README opt-in 表 / tasks-count gate 節（分割案節・env 表・ログ行） |
| Req 8.1〜8.6 | 下記「検証」 |
| NFR 1.1〜1.3 | Case E4〜E6（gate OFF 等価） |
| NFR 2.1〜2.4 | `tasks-count:` prefix の 1 行ログ。Case D3, F2, G2, G4, G6 |
| NFR 3.1〜3.6 | LLM 追加なし / API ≤2（Case G1）/ 本文 60,000 上限（Case A18 + 300 件手動計測 59,418 文字）/ タイトル 120（Case I1〜I4）/ 30 タスク 0.07s |
| NFR 4.1〜4.4 | `tc_sanitize_text` + Issue 番号 `^[0-9]+$` 検証 + `grep -F --`。Case G8〜G10, H1〜H7 |

## 検証（実行コマンドと結果）

- `shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh` → 警告ゼロ
- `shellcheck local-watcher/test/tasks_count_gate_split_proposal_test.sh` → 警告ゼロ
- `bash -n`（module / config / test）→ OK
- `bash local-watcher/test/tasks_count_gate_split_proposal_test.sh` → **PASS 76 / FAIL 0**
- `local-watcher/test/*_test.sh` 全 100 本 → 新規テスト含め回帰なし。
  `publish_terminal_failure_artifacts_test.sh` は rc=141（SIGPIPE）で **main でも同様に間欠失敗**する
  既存の flaky（本変更前後で同じ挙動を確認済み）。
- `diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules repo-template/.claude/rules` → 差分なし
- installer: `install-lib.sh:1317` が `modules/*.sh` を glob 配布するため変更不要（確認のみ）

## Open Questions への判断（requirements.md より）

1. **統合条件**: 暫定採用どおり **相互依存（循環）のみ統合**。一方向連鎖は統合せず案間 `Depends on:` で表現。
2. **コメント単位**: **独立コメント**を採用（既存 escalation コメント本文とマーカーを一切変更しないため / Req 6.4）。
3. **タイトル生成**: 最上位タスク要約を無害化 → 末尾 ` (P)` 除去 → 統合案は ` / ` 連結 → 120 文字で切り詰め（末尾 `…`）。
4. **`_Requirements:_` の同梱**: 本 Issue の必須項目に無いため**含めない**（AC 追加が必要なため人間判断待ち。下記「確認事項」）。
5. **warn レンジでの提示**: 要件どおり escalate のみ（Req 2.2）。
6. **gate 名称**: `TC_SPLIT_PROPOSAL_ENABLED` を採用。
7. **本文長上限時の縮退**: 未規定だったため **先頭から詰めて残りを省略 + 省略件数を本文に明記**する決定論的な縮退を実装。

## 確認事項（人間 / PM・Architect 判断）

- **`_Requirements:_` の子 Issue 案への同梱**（Open Question 4）: 起票後のトレーサビリティは上がるが
  Requirement 4 への AC 追加が必要。要件更新があれば `tc_extract_top_level_tasks` の 3 列目と同様に
  4 列目として追加できる構造にしてある。
- **`tc_sanitize_text` の除去文字**: 起票コマンド雛形（単一引用符で囲む）の破壊を防ぐため、要約から
  `'` `"` `` ` `` `$` `\` を**除去**している。表示上の情報が僅かに落ちる（例: `` `tasks.md` `` → `tasks.md`）。
  エスケープ方式に変えるべきかは運用フィードバック待ち。
- **`- [x]` 配下の `_Depends:_`**: 完了済み最上位タスク配下の依存注釈は帰属先なしとして読み飛ばす実装。
  完了タスクは案の構成単位にならないため実害はないが、仕様として明文化されていない。
- **タイトル案のロケール依存**: `${s:0:N}` は UTF-8 ロケールで文字単位、C ロケールでバイト単位。
  C ロケールでも文字数上限は満たすが、切り詰め位置が保守的になる（最大 1 文字余分に短くなる）。

STATUS: complete
