# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-185-impl-bug-labels-awaiting-slot-live-repo-root
- HEAD commit: 4ddb072a7318b049d5d0d4a37d28bb98efddbb46
- Compared to: main..HEAD

差分構成（`git diff --stat main..HEAD`）:

- `.github/scripts/idd-claude-labels.sh`（+1 / additive のみ）
- `install.sh`（+4 / コメントのみ）
- `README.md`（+6 / ドキュメント追記）
- `docs/specs/185-.../check-label-parity.sh`（+53 / 新規 standalone parity スクリプト）
- `docs/specs/185-.../requirements.md` / `impl-notes.md`（spec 成果物）

design.md / tasks.md は存在しない（PM フェーズのみの小規模 bug fix。Architect 未起動）。
そのため `_Boundary:_` アノテーションは無く、boundary 判定は requirements.md の
Out of Scope（`local-watcher/` 不編集・`repo-template/**` 不編集）を境界として代用した。

CLAUDE.md に `## Feature Flag Protocol` 節は存在しない → opt-out 解釈 → flag 観点の確認は
行わず、通常の 3 カテゴリ判定のみを適用した。

## Verified Requirements

- 1.1 — `.github/scripts/idd-claude-labels.sh:78` に `awaiting-slot|c5def5|...` を additive 追加。`grep awaiting-slot` で root に 1 行存在を確認
- 1.2 — root/template の name|color 集合 parity を独立に再現確認（`diff <(grep -oE '"[a-z-]+\|[0-9a-f]{6}\|' root) <(... template)` が exit 0）。`check-label-parity.sh` happy path も exit 0
- 1.3 — `git diff main..HEAD -- .github/scripts/idd-claude-labels.sh` が 1 行追加のみで削除・変更ゼロ。既存ラベル行の name/color/description は不変
- 1.4 — 追加行は template と同一の `【Issue 用】` #54 prefix 付き description を採用。root 既存ラベルの description 書き換えは無し（#54 prefix 温存）
- 1.5 — `check-label-parity.sh` の PAIR_REGEX `"[a-z-]+\|[0-9a-f]{6}\|` が name|color のみ抽出し description を比較対象外とすることをコード読みで確認
- 2.1 — `install.sh:1144` `copy_template_file` が template の labels スクリプトを再配置、`install.sh:1200` `setup_repo_labels "$REPO_PATH"` が起動する導線をコードで確認（template は既に awaiting-slot を持つため再 install で伝播）
- 2.2 — `idd-claude-labels.sh:131` の `--force` なし `gh label create` が失敗時に `already exists (skipped)` 分岐へ落ちる冪等パスを確認
- 2.3 — `install.sh:1196-1199` にコメント追記、README「新ラベルの再 install 伝播 (#185)」bullet 追加を diff で確認
- 2.4 — 既存導線が完備のため documentation のみで補強（Open Question で委ねられた範囲内の妥当判断）
- 2.5 — install.sh は `--force` なしで setup_repo_labels を起動、本変更は additive のみで削除・改名・color 変更なし
- 3.1 — additive 追加のみ。parity diff で既存ペアに差分なし
- 3.2 — labels スクリプトの引数処理（`--repo` / `--force`）に diff なし
- 3.3 — `install.sh:619-621` の `--no-labels` / `IDD_CLAUDE_SKIP_LABELS` opt-out 分岐に diff なし
- 3.4 — install.sh / labels スクリプトの env var 名・exit code に diff なし
- 3.5 — opt-out 分岐は不変のため導入前と同一挙動を維持
- NFR 1 — `--force` なしの既存ラベル skip 分岐により 2 回連続実行で 0 件作成・同一状態を担保
- NFR 2.1 — `check-label-parity.sh` drift path（root から awaiting-slot 除去した temp tree）で exit 1 + stderr に diff 出力を独立に再現確認
- NFR 2.2 — requirements.md Open Questions に自動化要否の委譲を明示。standalone スクリプト採用を impl-notes.md に記録
- NFR 3 — README 該当節を同一変更（1f6cf3e）で更新

## Findings

なし

## Summary

全 numeric AC（Req 1.x / 2.x / 3.x）および NFR 1 / 2.1 / 2.2 / 3 が、観測可能な実装と検証手段で
カバーされている。root への `awaiting-slot` 追加は additive のみで既存ラベル不変、root/template の
name|color parity は独立再現で exit 0、parity 検証スクリプトは happy/drift 双方で期待どおり動作。
boundary（`local-watcher/` / `repo-template/**` 不編集）も diff stat で遵守を確認。reject 対象なし。

RESULT: approve
