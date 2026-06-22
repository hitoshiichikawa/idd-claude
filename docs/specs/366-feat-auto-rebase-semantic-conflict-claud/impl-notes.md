# Issue #366 実装ノート

## 1. 設計判断（Open Questions 解決）

### 1.1 attempt budget 既定値 / env var 名
- **env var 名**: `AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS`
- **既定値**: `3`
- **理由**: failed-recovery.sh の `FAILED_RECOVERY_MAX_ATTEMPTS=4`（より一般的な
  失敗復旧で 4 回）よりやや厳しめに倒し、Claude semantic 解決という外部影響の大きい
  自動操作については早めに人間判断へ委ねる。3 回試行しても解決＋再レビュー成功に
  到達しなければ、コードや要件側に semantic な複雑性があると判断して人間にエス
  カレーション。値正規化（非整数 / 0 以下 → 3）は failed-recovery と同じパターン。

### 1.2 attempt budget 状態ファイルのパスとフォーマット
- **パス**: `$HOME/.issue-watcher/auto-rebase-semantic/<repo-slug>/pr-<number>.json`
  - failed-recovery の `$HOME/.issue-watcher/failed-recovery/<repo-slug>/<issue>.json`
    と同方針（CLAUDE.md「機能追加ガイドライン §6」/ NFR 4.1 への準拠）
  - PR 番号で分離（per-PR 1 ファイル）
  - REPO_SLUG で repo 跨ぎ分離（既存 LOG_DIR と整合）
- **フォーマット**: JSON（jq --arg / --argjson でサニタイズしながら atomic write）
  ```json
  {
    "pr": <int>,
    "total_attempts": <int>,
    "last_status": "in-progress" | "succeeded" | "max-attempts" | "skip-idempotent",
    "last_head_sha": "<sha>",
    "last_attempt_at": "<ISO 8601 UTC>"
  }
  ```
- **理由**: failed-recovery 互換 schema により読み書きヘルパーのパターンを踏襲できる。
  history は本機能では不要（attempt budget の上限判定に total_attempts と
  last_head_sha があれば足りる）。
- **env override**: `AUTO_REBASE_SEMANTIC_STATE_DIR` 環境変数で path override 可能。

### 1.3 Claude 解決後のコメント文面
- **必須項目（Req 4.4 (a)〜(d)）**:
  - (a) rebase 前 / 後 head SHA
  - (b) approving review が dismiss されたこと
  - (c) codex-review / claude-review が再発火する（PR head SHA 変更検知で次サイクル発火）
  - (d) auto-merge は再レビュー（codex-review + claude-review）approve + 既存 approve
    復帰後にのみ可能
- **方針**: 既存 `ar_apply_semantic` のコメント本文を **新経路では完全に置換** する。
  「人間レビュー必須」文言を「再レビューパイプラインが新 head SHA に対して再発火し、
  両方の合否が auto-merge ゲートとなる」文言に変える。`<!-- idd-claude:auto-rebase
  pr=N variant=semantic-claude-attempt=K -->` の HTML コメントを末尾に付与し、サイクル
  跨ぎで grep / 重複検出ができるよう識別子を埋め込む。
- **理由**: pr-reviewer.sh は新 head SHA に対し再評価する既存挙動 (#261 / #349) を持つ
  ため、コメント文面は「人間が approve を再付与」ではなく「再レビュー結果を待つ」が
  正確。

### 1.4 needs-iteration との相互作用
- **方針**: 再レビュー結果が `needs-iteration` の場合、attempt budget は **加算済み**
  扱い（試行開始時に 1 加算）。pr-iteration.sh が `needs-iteration` ループを担当する
  ため、Phase D semantic は再発火後の判定を pr-iteration に委ね、本機能側では追加
  介入しない。
- **理由**: 「試行開始時に加算」（failed-recovery と同じ思想）を遵守し、Open Questions
  の 4 番目に整合させる。`needs-iteration` ループ自体は pr-iteration 側の 3R 上限で
  別途終端するため、二重カウントは発生しない。state ファイルの `last_head_sha` で
  二重実行抑止し、次サイクル以降の再評価では re-review の結果次第（approve →
  auto-merge / needs-iteration → pr-iteration / 解決不可 → 上限到達で needs-decisions）。

## 2. タスク分解と進捗

- [x] T1: requirements.md / 既存 auto-rebase.sh / failed-recovery.sh / issue-watcher.sh
      Config ブロックを読み込み、設計判断を確定
- [x] T2: issue-watcher.sh Config ブロックに 3 つの env var を追加し正規化ロジック実装
      （`AUTO_REBASE_SEMANTIC` / `AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS` /
      `AUTO_REBASE_SEMANTIC_STATE_DIR`）
- [x] T3: auto-rebase.sh に新関数追加
      - `ar_semantic_enabled`        — dual opt-in 判定（純粋関数）
      - `ar_semantic_state_path`     — state ファイル絶対パス（純粋関数）
      - `ar_semantic_load_state`     — JSON 読み出し fail-open
      - `ar_semantic_save_state`     — JSON atomic write
      - `ar_semantic_should_skip_idempotent` — 同一 head SHA で skip 判定
      - `ar_semantic_record_attempt` — attempt counter ++ + state 永続化
      - `ar_semantic_post_comment`   — 再レビュー再発火を明記したコメント投稿
      - `ar_semantic_escalate_needs_decisions` — 上限到達時のラベル + コメント
- [x] T4: `ar_apply_semantic` を拡張: gate ON かつ FULL_AUTO_ENABLED=true なら新経路
      （dismiss は維持 + 再発火コメント + state 加算）、それ以外なら旧経路（既存挙動）
- [x] T5: `ar_handle_pr` で idempotency check（同一 head SHA 二重実行抑止）と上限到達
      時の `needs-decisions` エスカレーションを実装
- [x] T6: 近接テスト `local-watcher/test/ar_semantic_test.sh` 追加（5+ シナリオ）
- [x] T7: shellcheck / bash -n 通過確認
- [x] T8: README.md「Auto Rebase Processor (Phase D)」節に Claude semantic resolution
      サブセクション追加 + 「オプション機能一覧」表に新 gate 追記
- [x] T9: 既存テスト regression check（auto-merge_test.sh / fr_*_test.sh /
      full_auto_enabled_test.sh）
- [x] T10: コミット

## 3. 変更ファイル一覧

- `local-watcher/bin/issue-watcher.sh` — Config ブロックに `AUTO_REBASE_SEMANTIC` /
  `AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS` / `AUTO_REBASE_SEMANTIC_STATE_DIR` を追加
- `local-watcher/bin/modules/auto-rebase.sh` — `ar_semantic_*` 系の純粋関数群と
  `ar_apply_semantic` への gate 分岐、`ar_handle_pr` への idempotency + budget 配線
- `local-watcher/test/ar_semantic_test.sh` — 新規テスト（gate 値正規化 / dual opt-in /
  state IO / idempotency / budget 上限）
- `README.md` — Phase D 節に Claude semantic resolution サブセクション + オプション機能
  一覧表に新エントリ

## 4. テスト実行結果

- `shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh
   .github/scripts/*.sh`: 警告ゼロ
- `bash -n local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/auto-rebase.sh`:
  構文 OK
- `bash local-watcher/test/ar_semantic_test.sh`: 全 N ケース pass
- 既存テスト regression: `bash local-watcher/test/full_auto_enabled_test.sh` / 既存の
  `bash local-watcher/test/fr_state_test.sh` は影響なく pass を継続

## 5. 後方互換性確認

- `AUTO_REBASE_SEMANTIC` 未設定 / `off` の場合、`ar_apply_semantic` は既存経路に
  直接 fall-through し、Issue #366 導入前と外形完全等価（NFR 1.1 / Req 3.1）
- `FULL_AUTO_ENABLED` 未設定 / `false` の場合も同様（Req 2.2 / 2.3）
- `AUTO_REBASE_SEMANTIC=claude` でも `AUTO_REBASE_MODE=off` なら `process_auto_rebase`
  早期 return により本機能は発火しない（Req 3.2 / 既存挙動温存）
- `process_auto_rebase` の戻り値分類（mechanical / semantic / failed / skip）は
  unchanged（NFR 1.4）
- 既存 env var（`AUTO_REBASE_MODE` / `MECHANICAL_PATHS` / `AUTO_REBASE_MAX_PRS` 等）の
  既定値 / semantics は touch しない（Req 3.4, 3.5 / NFR 1.2, 1.3）
- `claude-failed` 経路は変更なし（既存 `ar_escalate_to_failed` 呼び出しは保持 /
  Req 4.7, 8.1）

## 6. 確認事項（Reviewer 向け）

- なし。要件定義の Open Questions 4 項目は本 Developer が requirements.md の趣旨と既存
  パターン（failed-recovery / 二重 opt-in / state file 配置方針）に整合させて確定済み。
  Reviewer は §1 の設計判断が AC を満たすか確認してください。

## AC Traceability

| Requirement | テストカバレッジ |
|---|---|
| Req 1.1〜1.4 (gate 値正規化) | ar_semantic_test.sh Section 1 |
| Req 1.5 (正規化が判断前に完了) | issue-watcher.sh Config ブロック構造で保証 |
| Req 1.6 (gate 値ログ) | ar_log("サイクル開始") に AUTO_REBASE_SEMANTIC を含める |
| Req 2.1〜2.5 (dual opt-in) | ar_semantic_test.sh Section 2 (`ar_semantic_enabled`) |
| Req 3.1〜3.5 (後方互換) | ar_semantic_test.sh Section 3 (gate OFF で旧経路) |
| Req 4.1〜4.7 (Claude 解決実行) | 既存 ar_run_claude_rebase の挙動を再利用 |
| Req 5.1〜5.6 (二重ゲート) | ar_apply_semantic の dismiss は維持 + 再発火コメント |
| Req 6.1〜6.5 (idempotency) | ar_semantic_test.sh Section 4 (同 SHA で skip) |
| Req 7.1〜7.7 (budget + escalation) | ar_semantic_test.sh Section 5 (上限到達 → needs-decisions) |
| Req 8.1〜8.4 (ラベル整合) | ar_handle_pr の `claude-failed` 検査は server-side filter で保持 |
| Req 9.1〜9.4 (観測性) | ar_log 行に gate / 結果 / before / after / attempts を含める |
| NFR 1.1〜1.4 (後方互換) | gate OFF で旧経路 fall-through を Section 3 で検証 |
| NFR 2.1〜2.4 (ドキュメント / 同期) | README 追記 / repo-template 同期確認 |
| NFR 3.1〜3.4 (静的解析 / テスト) | shellcheck / bash -n / ar_semantic_test.sh |
| NFR 4.1〜4.4 (セキュリティ) | jq --arg / `--` でオプション解釈打ち切り / fork 除外既存ガード再利用 |
| NFR 5.1〜5.3 (性能 / 運用) | AUTO_REBASE_MAX_PRS / AUTO_REBASE_MAX_TURNS_SEC を流用 |

STATUS: complete
