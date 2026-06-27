# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-27T19:50:00Z -->

## Reviewed Scope

- Branch: claude/issue-412-impl-enhancement-pr-reviewer-404-adjudicator
- HEAD commit: 48acaf29408c3ffcf85b459128596ad1a663cc54
- Compared to: main..HEAD
- 変更統計: 11 files, +1210 / -73（うち実装 = issue-watcher.sh / adjudicator.sh / pr-reviewer.sh / labels script x2、テスト = 新規 2 + 既存 1 のコメント更新、ドキュメント = README + spec docs）
- 注記: 本 Issue では `tasks.md` / `design.md` が生成されていない（単一実装パス）。Boundary 判定は requirements.md の「Out of Scope」節と既存モジュール責務に照らして行った。

## Verified Requirements

### Requirement 1: `PR_REVIEWER_ADJUDICATOR_ENABLED` 既定反転（default ON / opt-out）

- 1.1 — 未設定 → ON 正規化: `issue-watcher.sh:697` の `${PR_REVIEWER_ADJUDICATOR_ENABLED:-true}` + `case false) :;; *) true`（L700-703）+ 後段「デフォルト有効化フラグの値正規化」ループ（L1359-1379）の 2 段正規化。test: `pr_reviewer_adjudicator_default_on_test.sh` Req 1.1 PASS。
- 1.2 — 空文字 → ON: 同上正規化（`${VAR:-true}` で空文字は default に倒れる）。test: 同 Req 1.2 PASS。
- 1.3 — `=true` → ON: 同上。test: Req 1.3 PASS。
- 1.4 — `=false` → OFF: `case false) :;;` で `false` 厳密一致のみ通過。test: Req 1.4 / 5.1 PASS。
- 1.5 — `False` / `FALSE` / `True` / `TRUE` / `1` / `0` / typo → ON: `case *) true ;;` の網羅 fallback。test: Req 1.5 8 cases PASS。
- 1.6 — 起動時ログで判別可能: `issue-watcher.sh:1533` の cycle startup echo に `pr-reviewer-adjudicator=${PR_REVIEWER_ADJUDICATOR_ENABLED}` 追加。impl-notes に cron-like dry-run の出力確認記載あり。

### Requirement 2: `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` 既定の見直し

- 2.1 — 未設定 = passthrough 既定: `issue-watcher.sh:725` の `${...:-passthrough}` を **意図的に維持**（Req 2.1 と整合）。impl-notes 設計判断 2 で理由明示。
- 2.2 — `=legitimate` → 徹底安全側: `issue-watcher.sh:726-728` の既存 case 文不変。
- 2.3 — typo → passthrough 正規化: 同 case 文の `*) passthrough` で安全側正規化。
- 2.4 — claude 失敗時の fallback 分岐: `adjudicator.sh` 既存 fallback 実装不変。
- 2.5 — README に根拠明示: `README.md` の「`PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` の意味」節に「#412 default ON 化後も `passthrough` を維持する根拠（SPOF 緩和 / claude-review publisher contention）」を追記。

### Requirement 3: README / 運用ドキュメント整備

- 3.1 — publisher 責務分担: README に新規節「`claude-review` publisher 契約」追加（adjudicator / catch-up / Design PR Reviewer の発火順 1/2/独立を明示）。
- 3.2 — marker 判定規則: 同節で adjudicator marker (`<!-- idd-claude:pr-adjudicator sha=<sha> -->`) と catch-up の defer 関係を明示。
- 3.3 — codex 併用時の推奨組み合わせ: 新規節「推奨設定の組み合わせ（codex 運用時 / #412 default ON 化後）」に 4 シナリオ × env 値 + branch protection 推奨を表で記載。
- 3.4 — migration note: 「Migration Note（既存ユーザー向け）」節先頭に「⚠️ #412 で既定反転」項目追加。
- 3.5 — `issue-watcher.sh` コメント書き換え: L661-695 のコメントブロックから「完全な opt-in / 既定 OFF」を削除し「既定 ON / `=false` で opt-out」表現に書き換え。`adjudicator.sh` L12-17, L52-58 も同期更新。

### Requirement 4: `claude-review` 必須化 repo の merge gate 不充足 PR 可視化

- 4.1 — 停滞状態のログ: `pr-reviewer.sh:process_claude_review_merge_gate_visibility` 内で `pr_log "merge-gate-visibility: PR #${pr_number} sha=${sha} 停滞検知（required=claude-review / adjudicator marker 不在 / claude-review status 未 publish）"` を 1 行出力。test: `mgv_merge_gate_visibility_test.sh` Req 4.1 系 3 cases PASS。
- 4.2 — 可視化手段（label / comment / status 1 つ以上）: `needs-merge-gate-attention` ラベル付与（`mgv_add_attention_label`）。`.github/scripts/idd-claude-labels.sh` と `repo-template/.github/scripts/idd-claude-labels.sh` の両系統に同期追加（L82, L78）。
- 4.3 — 解消時の冪等取り消し: ケース 1（claude-review status 既 publish）/ ケース 2（adjudicator marker あり）の両分岐で `mgv_remove_attention_label` を呼ぶ。`gh pr edit --remove-label` は未付与でも no-op 冪等。test: Req 4.3 3 cases PASS。
- 4.4 — fallback 経路優先: `process_claude_review_merge_gate_visibility` を `process_claude_review_status_catchup` の **直後**（issue-watcher.sh:1981）に配置。catch-up が成功 → ケース 1、adjudicator が成功（marker あり） → ケース 2、両方失敗 → ケース 3 のみ可視化発火。test: marker sha 不一致での非発火確認 PASS。
- 4.5 — README に推奨対応手順: 「`claude-review` 必須化シフトの consumer 手順」節に「5. 停滞 PR 可視化」を追加し 4 種の解消策（`PR_REVIEWER_ENABLED=true` 化 / catch-up 二重 opt-in / 設計 PR の `DESIGN_REVIEWER_ENABLED` 経路 / admin 手動 merge）を列挙。

### Requirement 5: 後方互換性

- 5.1 — `=false` 明示環境で本変更前と等価: `case false) :;;` で `=false` 厳密一致のみ通過 + 後段ループも `false` を維持。`adj_gate_enabled` は厳密 `=true` 判定で `false` は早期 return 1 → 追加呼び出しゼロ。test: `pr_reviewer_adjudicator_default_on_test.sh` Req 5.1 + `adj_resolve_gate_test.sh` PASS。
- 5.2 — `=true` 明示環境で ON 維持: 同正規化で `true` 維持。test: Req 5.2 PASS。
- 5.3 — 他の `PR_REVIEWER_ADJUDICATOR_*` env 不変: `issue-watcher.sh:703-736` の MODEL / EXEC_TIMEOUT / PROMPT / FALLBACK_ON_FAIL / MAX_FINDINGS は本 PR で touch なし（git diff で確認）。
- 5.4 — env 名 / path / exit code / cron 文字列不変: env 名 `PR_REVIEWER_ADJUDICATOR_ENABLED` を変更せず（既定値のみ反転）、cron 文字列の解釈規則は不変。
- 5.5 — ラベル名 / commit status 名不変: `needs-iteration` / `claude-review` / `codex-review` 不変（新規 `needs-merge-gate-attention` は追加のみ）。
- 5.6 — log prefix 不変: `[adjudicator]` / `[pr-reviewer]` 等の prefix 形式不変。

### Requirement 6: ドキュメント二重管理同期

- 6.1 — agents byte 一致: `diff -r .claude/agents repo-template/.claude/agents` 空出力で確認。
- 6.2 — rules byte 一致: `diff -r .claude/rules repo-template/.claude/rules` 空出力で確認。
- 6.3 — 同一 PR で README 更新: README に publisher 契約節 / 推奨組み合わせ表 / migration note を追加。
- 6.4 — コメントと README 整合: `issue-watcher.sh` / `adjudicator.sh` のコメントが README の表記（default ON / opt-out / `=false` 厳密一致のみ無効）と一致。

### Requirement 7: 静的解析 / スモークテスト

- 7.1 — shellcheck 警告ゼロ: `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh` 出力なし（rc=0）で確認。
- 7.2 — 最小 PATH で default ON 起動: impl-notes に cron-like 最小 PATH での `pr-reviewer-adjudicator=true` 出力確認記載。
- 7.3 — 各 env 値での解決スモーク: `pr_reviewer_adjudicator_default_on_test.sh` 16 cases ですべて検証 PASS。
- 7.4 — dry-run exit code 維持: 本 PR で touch していない経路の動作を impl-notes で言及。

### NFR

- NFR 1.1 / 1.2 / 1.3 — 後方互換性: 上記 Req 5.x と同。
- NFR 2.1 — 観測ログ粒度: merge-gate-visibility は 1 サイクル 2 行 + 1 行 / PR で既存粒度と同等。
- NFR 2.2 — 可視化発火の根拠 grep 可能: `merge-gate-visibility:` prefix + required ステータス名 + 不在理由を含む 1 行ログで確認可能。
- NFR 3.1 — self-hosting 最小影響: 既存 `claude-failed` / `passthrough` 既定維持 / `PR_REVIEWER_ADJUDICATOR_ENABLED=false` 明示済環境は同一挙動。impl-notes 確認事項 1-5 で self-hosting 影響を申し送り済。

## Boundary 検証

- 変更ファイル 11 件はすべて以下のスコープに収まる:
  - `local-watcher/bin/issue-watcher.sh` / `modules/adjudicator.sh` / `modules/pr-reviewer.sh`: PR Reviewer Adjudicator 関連の既存責務
  - `local-watcher/test/*`: 近接テスト追加（CLAUDE.md「機能追加ガイドライン §7」準拠）
  - `README.md`: 挙動変更の同期反映（同 §4 README 二重管理ルール）
  - `.github/scripts/idd-claude-labels.sh` + `repo-template/...`: 新規ラベル追加で root↔repo-template 同期（同 §4 鉄則）
  - `docs/specs/412-*/`: spec ディレクトリ
- 新規 `mgv_*` namespace は CLAUDE.md「機能追加ガイドライン §2」prefix 規約に従い、既存 `pr_*` / `adj_*` と衝突せず、`pr-reviewer.sh` 末尾に同居（同 §1 既存責務同居方針）。
- `PR_REVIEWER_ADJUDICATOR_ENABLED` の既定反転は #112 と同じ「default ON / `=false` で OFF」パターン踏襲で、CLAUDE.md「禁止事項」節の `#112 既定値反転は対象外` 例外条項と整合。

## Findings

なし

## Summary

#412 の要件定義（Req 1〜7 + NFR 1〜3、31 numeric AC ID）はすべて実装 + 78 tests 全 PASS + shellcheck 警告ゼロ + root↔repo-template byte 一致で網羅されている。default 反転は `=false` 厳密一致のみ OFF とする安全側正規化で後方互換を維持し、`passthrough` fallback 既定維持の根拠も README に明示済。merge gate visibility processor は catch-up 直後に配置され、Req 4.4 の fallback 優先順位が正しく機能する。

RESULT: approve
