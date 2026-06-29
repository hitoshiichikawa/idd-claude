# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.8 timestamp=2026-06-29T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-438-impl--bootstrap-cmd-main-di-issue-merge-confl
- HEAD commit: 13da002f885e52df3bfe822aae3f79a4a361aed2
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節は存在しない（rules 表の参照のみ）。通常の 3 カテゴリ判定を適用

## Verified Requirements

- 1.1 — gate 未設定/無効値で緩和を起動せず従来判定。`AUTO_REBASE_ADDITIVE` 既定 `off` + `case` 正規化（`issue-watcher.sh`）、`ar_classify_diff` は `AUTO_REBASE_ADDITIVE=claude` 時のみ二次判定を呼ぶ。test `ar_additive_test.sh` §1.1 / §2.1
- 1.2 — gate 有効値で緩和経路を起動。`ar_classify_diff` の `first_unmatched` 後フックが `claude` 時に `ar_classify_additive` を呼び mechanical 昇格。test §2.3
- 1.3 — 不正値を無効同等に扱う。`issue-watcher.sh` の `case ... *) off` 正規化 + test §1.1b（`CLAUDE`/`on`/`true`/空/`additive` → gate-off）
- 1.4 — 緩和有効でも paths 空なら従来判定へフォールバック。`ar_classify_additive` の `paths-empty` 分岐。test §1.2
- 2.1 — 全 path bootstrap allowlist 閉 + 全 hunk 追加のみで `mechanical` 判定。`ar_classify_additive` → `additive`、フックが `echo mechanical`。test §1.3 / §2.3
- 2.2 — 削除/変更行含みで `semantic` フォールバック。本体 hunk `-*` 検出 → `non-additive-hunk`。test §1.4 / §2.4
- 2.3 — allowlist 外 path 混在で `semantic` フォールバック。`first_unmatched` → `path-out`。test §1.5 / §2.5
- 2.4 — diff 取得失敗で保守的に `semantic`（`diff-failed` + return 1）。`git diff --name-only` / unified 双方の失敗分岐。test §1.6(a)(b)
- 2.5 — `additive` 判定時に対象 path と理由を `ar_log` 記録（`additive=additive ... paths=...`）。test §1.3（log_has）
- 3.1 — 加算的 mechanical 判定の副作用を既存 mechanical 経路と同一に保つ。新規副作用コードを追加せず `echo mechanical` で既存 `ar_apply_mechanical`（needs-rebase 除去のみ・approve 維持・コメントなし）へ合流する構造的再利用。test §2.3 が分類出力 `mechanical` を確認
- 3.2 — 和集合解決後の必須 status check を迂回しない。mechanical 経路の merge gating は不変（新規迂回コードなし）。README で明示
- 3.3 — approve 維持時に semantic 副作用（dismissal / ready-for-review / コメント）を行わない。分類を mechanical に振ることで semantic 分岐へ流れない。test §2.3 / §2.4 が経路分離を確認
- 4.1 — `design-principles.md` に bootstrap 一極集中の merge conflict ホットスポット課題と self-register 回避指針を記述（新節「bootstrap 一極集中の回避」）
- 4.2 — 複数ドメインの加算的追記検討時に self-register を評価対象提示（「適用条件: 加算的追記の集中が見えたら評価対象にする」節）
- 4.3 — 強制レベルを誤読されない形で明示（節冒頭 blockquote「本節は **推奨（指針）であり必須ではありません**」）
- 5.1 / 5.2 — root と `repo-template/.claude/rules/design-principles.md` が byte 一致。`diff` / `diff -r .claude/rules repo-template/.claude/rules` ともに差分ゼロを確認
- NFR1.1 — gate 未設定で導入前と完全同一の外部挙動。gate OFF で `ar_classify_additive` を一切呼ばない（ログ未発火含む）。test §1.1 / §2.1
- NFR1.2 — 既存 env var 名（`AUTO_REBASE_MODE` / `MECHANICAL_PATHS` 等）・ラベル・exit code を不変、新 env var を追加のみ。README に migration note
- NFR1.3 — `MECHANICAL_PATHS` のみ設定 + additive gate 未設定で従来判定のみ。test §2.1 / §2.2
- NFR2.1 — 情報取得不能で `semantic` 側へ倒す。`diff-failed` + return 1。test §1.6
- NFR2.2 — 削除/変更行を含む hunk を mechanical 対象に含めない。`-*` / rename / mode / binary を安全側除外。test §1.4
- NFR3.1 — 判定結果と理由を運用者追跡可能なログへ出力。`ar_log` 記録 + サイクル開始ログに `additive=` / `additive-paths=` 併記
- NFR4.1 — README「Auto Rebase Processor (Phase D)」節に新 env gate・分類表行・migration note を同一変更で反映

## Findings

なし

## Summary

全 numeric ID（Req 1〜5 / NFR1〜4）に対応する実装またはテストを diff 内に確認。`ar_additive_test.sh` を再実行し 38/38 PASS、`bash -n` / `shellcheck` クリーン、`diff -r .claude/rules repo-template/.claude/rules` 差分ゼロを確認。tasks.md の `_Boundary:_`（`ar_classify_additive` / `ar_classify_diff` / `design-principles.md`）と変更ファイルが整合し、宣言外コンポーネントへの変更なし。Req 3 系は既存 `ar_apply_mechanical` への構造的合流（新規副作用コードなし）で担保され、結線テストが分類出力を検証済み。

RESULT: approve
