# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-18T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-112-impl-feat-watcher-opt-in-env-var-9-true
- HEAD commit: f95bc210605c76da6f6ddee81c2474c61e87a5b9
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/issue-watcher.sh` / `README.md` / `CLAUDE.md` /
  `repo-template/CLAUDE.md` / `repo-template/.claude/agents/developer.md` /
  `repo-template/.claude/agents/project-manager.md` / `.claude/agents/developer.md` /
  `docs/specs/112-feat-watcher-opt-in-env-var-9-true/{requirements,impl-notes}.md`
- Feature Flag Protocol: ルート `CLAUDE.md` に `## Feature Flag Protocol` 節は存在せず
  （opt-out 扱い）。flag 観点の細目チェックは適用しない。
- tasks.md / design.md は本 spec ディレクトリに存在せず（Triage が `feat-impl` で Architect
  を経由しないルートと推定。`_Boundary:_` 制約は requirements.md Out of Scope 節と Req 4
  の対象ファイル列挙を boundary とみなして照合）。

## Verified Requirements

### Requirement 1: デフォルト有効化（未設定で ON）
- 1.1 — `local-watcher/bin/issue-watcher.sh:83` `MERGE_QUEUE_ENABLED:-true` +
  normalization loop (L229–245) + gate `process_merge_queue` 862 行で `!= "true"` 検証
- 1.2 — `local-watcher/bin/issue-watcher.sh:104` `MERGE_QUEUE_RECHECK_ENABLED:-true` +
  gate L1016
- 1.3 — `local-watcher/bin/issue-watcher.sh:112` `PR_ITERATION_ENABLED:-true` + gate L2009
- 1.4 — `local-watcher/bin/issue-watcher.sh:135` `PR_ITERATION_DESIGN_ENABLED:-true` +
  jq `$design_enabled == "true"` 経路 L1189 / L2037 / L1551
- 1.5 — `local-watcher/bin/issue-watcher.sh:147` `DESIGN_REVIEW_RELEASE_ENABLED:-true` +
  gate L2247
- 1.6 — `local-watcher/bin/issue-watcher.sh:163` `STAGE_CHECKPOINT_ENABLED:-true` +
  `run_impl_pipeline` 冒頭 L3549 でも `:-true` に揃え（Config ブロック未通過パスの防御）
- 1.7 — `local-watcher/bin/issue-watcher.sh:188` `QUOTA_AWARE_ENABLED:-true` + gate L460 /
  L647
- 1.8 — `local-watcher/bin/issue-watcher.sh:212` `IMPL_RESUME_PRESERVE_COMMITS:-true` +
  `_resume_branch_init` L4528 が `_resume_normalize_flag preserve_default_off` 経由で
  `"true"` に解決し、Config 上部の正規化と整合
- 1.9 — `local-watcher/bin/issue-watcher.sh:221` `IMPL_RESUME_PROGRESS_TRACKING:-true`
  （#67 既存値据え置き）+ `build_prompt_a` L2734–2783 で正規化済み値を読む

### Requirement 2: 明示 `=false` で opt-out 維持
- 2.1〜2.9 — 正規化ループ L239 `if [ "${!_idd_flag}" = "false" ]` で `=false` 完全一致時
  のみ `"false"` に固定。下流 gate はすべて `= "true"` / `!= "true"` 判定で、`=false` 明示
  時は本機能導入前と等価の skip パスへ倒れる
- 2.10 — 同正規化ループの `else` 分岐で `=false` 以外（空 / `0` / `False` / `Yes` /
  `enabled` / typo）は `"true"` に倒す。impl-notes Test 4 で 15 ケース確認済み

### Requirement 3: 後方互換性
- 3.1 — `=true` 明示時の動作は本変更前と完全一致（normalization で再度 `"true"` に固定）。
  `qa_run_claude_stage_test.sh` 等既存 161 件 PASS で検証済み（impl-notes.md L99–113）
- 3.2 — `=false` 明示時は normalization で `"false"` 確定。`qa_run_claude_stage_test.sh`
  の opt-out 経路テスト含む 24 ケース PASS
- 3.3 — env var 名・スペル・参照 path・exit code への変更なし（diff 確認）
- 3.4 — `needs-quota-wait` / `awaiting-design-review` / `needs-rebase` / `claude-failed`
  等のラベル名は diff で変更なし
- 3.5 — 起動時 log の `[時刻] base-branch=main merge-queue-base=main` prefix は L287 で
  不変。impl-notes の dry run でも実出力確認済み

### Requirement 4: ドキュメント整合
- 4.1 — `README.md` 「オプション機能（標準有効 / 常時有効）一覧」節を再構成し、対象 9
  種を「デフォルト有効」表に分離（`true` 列で統一）
- 4.2 — 各機能セクション（Merge Queue / Re-check / PR Iteration / 設計 PR 拡張 /
  Design Review Release / Quota-Aware / impl-resume Branch Protection / Stage
  Checkpoint）の環境変数表で既定列を `true`（#112）に更新、推奨欄を「無効化する場合
  のみ `false`」に統一
- 4.3 — README 「オプション機能（標準有効 / 常時有効）一覧」節冒頭に `**Migration Note
  (#112, 2026-05-18)**` のインライン note ブロックを追加。対象 8 種列挙・値解釈規約・
  env var / ラベル / exit code / log prefix の不変性を明記
- 4.4 — `local-watcher/bin/issue-watcher.sh` 各 env var 宣言行直上のコメント 8 ヶ所を
  「初回導入は opt-in（デフォルト false）」から「標準機能としてデフォルト有効（#112）」
  相当の文言に書き換え（L80-83, L101-104, L109-112, L132-135, L143-147, L159-163,
  L185-188, L206-212）。`STAGE_CHECKPOINT_ENABLED` のコメントブロックには「`=false` 以外
  はすべて有効」の明記もあり Req 2.10 と整合
- 4.5 — `CLAUDE.md` L154 の禁止事項「opt-in gate なしで新しい外部サービス呼び出しを
  有効化」項に「**注**: #112 で実施した『既に main で稼働しデフォルト false で配置
  された機能』のデフォルト反転（`MERGE_QUEUE_ENABLED` 等 8 種）は本禁止事項の対象外」
  の migration note 参照を追加

### Requirement 5: Developer prompt 注入経路
- 5.1 — `build_prompt_a` L2734 の gate `[ "$mode" = "impl-resume" ] && [
  "${RESUME_PRESERVE:-false}" = "true" ]` 内で `tracking="true"` 分岐 (L2739–2755) が
  進捗追跡指示を含む `progress_block` を生成
- 5.2 — 同 gate 内 `tracking="false"` 分岐 (L2756–2763) で「進捗マーカーを書き換えない」
  指示を出力
- 5.3 — `RESUME_PRESERVE` は `_resume_branch_init` L4528 が export し、
  `IMPL_RESUME_PRESERVE_COMMITS=false` 時は `RESUME_PRESERVE=false` を export。L2734 の
  外側 gate で `resume_section=""` のまま prompt に注入されず、`IMPL_RESUME_PROGRESS_TRACKING`
  の値に関わらず進捗追跡指示は欠落する
- 5.4 — `_resume_branch_init` の if 分岐構造は維持され、`PRESERVE=false` 経路で本機能
  導入前と等価の `origin/$BASE_BRANCH` 起点 force-with-lease push が走る (L4536–4546)

### Non-Functional Requirements
- NFR 1.1 — `=true` 明示済み既存環境では normalization が再度 `"true"` に固定するため
  影響なし。impl-notes Test 3 で 9/9 PASS、既存 161 件テスト全 PASS
- NFR 1.2 — `=false` 明示済み既存環境も normalization が `"false"` を保つため opt-out
  挙動が継続。`qa_run_claude_stage_test.sh` opt-out テスト PASS で確認
- NFR 1.3 — env var 名 / ラベル名 / exit code 意味 / log prefix `base-branch=` のいずれも
  diff 上で変更なし
- NFR 2.1 — `shellcheck -S warning` exit 0（impl-notes.md L42–51）
- NFR 2.2 — `env -i HOME=$HOME PATH=/usr/bin:/bin` で `gh / jq / flock / git / timeout`
  解決確認（impl-notes.md L55–62）。`claude` は冒頭の PATH prepend で補正
- NFR 3.1 — dogfooding 中の現行 cron は `=true` 明示済みのため normalization 後も挙動
  不変

### Out of Scope の遵守確認
- `PARALLEL_SLOTS` / `Feature Flag Protocol` / `IDD_CLAUDE_USE_ACTIONS` は反転対象外。
  README の「opt-in（既定 OFF）」表に残置されており Out of Scope と整合

### Boundary 違反確認
- 主要変更は `local-watcher/bin/issue-watcher.sh`（Req 4.4 対象）と `README.md`（Req 4.1
  〜4.3 対象）と `CLAUDE.md`（Req 4.5 対象）に集約され、要件で許可された境界内
- 追加で `repo-template/CLAUDE.md` / `repo-template/.claude/agents/developer.md` /
  `repo-template/.claude/agents/project-manager.md` / `.claude/agents/developer.md` の
  4 ファイルが変更されているが、いずれも本変更で参照される env var の opt-in 表記を
  「#112 以降デフォルト有効」に追随するための最小修正であり、対象 env var の意味論を
  外部から記述している箇所のドキュメント整合（Req 4 の趣旨の伸長）として妥当。
  consumer repo に伝播する `repo-template/**` の変更も挙動互換（テキスト変更のみ）

## Findings

なし

## Summary

Req 1.1〜1.9（未設定で ON）、Req 2.1〜2.10（`=false` 明示時のみ skip、それ以外は ON）、
Req 3.1〜3.5（後方互換）、Req 4.1〜4.5（ドキュメント整合）、Req 5.1〜5.4（impl-resume
prompt 注入経路の意味論維持）、NFR 1.1〜3.1 のすべてが、`local-watcher/bin/issue-watcher.sh`
冒頭 Config ブロックの値正規化ループ + 各 env var の `:-true` リテラルへの統一 + 既存
gate 構造の温存で達成されている。Out of Scope の `PARALLEL_SLOTS` / Feature Flag
Protocol / GitHub Actions は意図的に変更対象外で残置。impl-notes.md の AC 対応表で
全 AC のトレーサビリティが確認できる。

RESULT: approve
