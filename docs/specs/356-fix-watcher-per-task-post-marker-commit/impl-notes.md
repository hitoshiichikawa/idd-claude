# Implementation Notes — Issue #356

## 概要

per-task Reviewer 起動前の post-marker commit safety net (`pt_detect_post_marker_commits` /
`pt_handle_post_marker_commits`) を、docs-only post-marker commit に対しては fail させずに
marker を auto-refresh して続行する形に拡張した（Fix A）。併せて Developer agent の Marker
contract に「impl-notes / learning 追記は marker より前、marker は task の最終 commit」
順序条項を追記し、そもそも docs-only post-marker commit を生まない契約強化を行った（Fix B）。

## Fix A: watcher 側 docs-only auto-refresh

### 変更ファイル
- `local-watcher/bin/issue-watcher.sh` — env `POST_MARKER_DOCS_ALLOWLIST` 追加 /
  `pt_classify_post_marker_paths` 新設 / `pt_handle_post_marker_commits` への docs-only
  判定前段の組み込み / `pt_post_docs_only_auto_refresh_comment` 新設 / `run_per_task_reviewer`
  の recovery 種別ログ分岐
- `local-watcher/test/pt_post_marker_classify_test.sh` — 単体 8 ケース + 統合 5 ケース +
  境界 3 ケースの計 39 アサーション

### 設計判断

- **docs allowlist の決定根拠**: 要件 Req 1.1 / 1.5 が「impl-notes.md / docs/specs/**/*.md
  相当の運用者観点で文書のみと判別できるパス集合」と抽象化していたため、Open Question
  「README.md / CLAUDE.md / .claude/** ルール類の扱い」は **既定では含めず最小集合**
  （`**/impl-notes.md,docs/specs/**/*.md`）に倒した。理由: docs-only 発火の主用途は
  `docs(impl-notes): learning 追記` 救済であり、`CLAUDE.md` / `README.md` 等のドキュメント変更
  は Developer 契約上 marker と分離した別 task で扱うべきもの。allowlist は env 経由で運用者
  が拡張可能（カンマ区切り glob パターン）にしているため、必要に応じて override できる。
- **mode dispatch との関係**: docs-only 判定を mode dispatch の **前段**（`extend-range`
  以外のときのみ）に置くことで、Req 3.3「`extend-range` は docs-only にオーバーライドされない」
  を満たした。`extend-range` mode 時は本判定を完全に skip して既存挙動を温存する。不正値
  正規化（`fail-with-diagnostic` への fallback）は判定後に適用されるが、判定対象は
  `extend-range` 以外なので不正値 → fallback → docs-only auto-refresh の経路も正常に動く
  （test Case E で確認）。
- **auto-refresh 手段（marker を tip に進める操作）の具体**: 「marker commit を物理的に
  rebase で末尾移動する」のではなく、**Reviewer の review range を HEAD まで拡張する**
  形（`pt_handle_post_marker_commits` 返却値を `<range_start>\t<HEAD_SHA>` にする）で実現。
  この方式は既存の `extend-range` mode と同じ仕組みであり、git 操作（reset/rebase）を
  行わないため副作用ゼロ。実装上は `pt_handle_post_marker_commits` の rc=0 経路を 2 種類
  （`extend-range` と `docs-only-auto-refresh`）共有しつつ、`run_per_task_reviewer` で
  `POST_MARKER_RECOVERY_MODE` の正規化値を見て recovery 種別を判別する。
- **Issue コメントの重複抑制**: `pt_post_docs_only_auto_refresh_comment` は
  `pt_mark_post_marker_commits_detected` と同じ HTML コメントマーカー方式で重複抑制
  （`<!-- idd-claude:per-task-post-marker-docs-only-auto-refresh:#<issue>:<task> -->`）。
  ただし「追記コメント」モードは持たず、同一 task で auto-refresh が複数回発火しても 1 件
  のみ投稿する設計（Issue コメント増殖を抑制 / NFR 1.3）。

## Fix B: Developer agent Marker contract 強化

### 変更ファイル
- `.claude/agents/developer.md` — Marker contract 節に「順序条項（Issue #356 / 必読）」
  サブセクション追加 + 「watcher 側 safety net との関係」に docs-only auto-refresh の説明追加
- `repo-template/.claude/agents/developer.md` — root と byte 一致で同期

### 設計判断
- 既存 Marker contract 節の「marker 作成タイミングの契約」は順序を暗黙化していたため、
  Req 4.1 が要求する明示性を満たすには専用サブセクション「順序条項」を新設するのが妥当
  と判断した。既存サブセクション（「retry 時の marker refresh 契約」「推奨 refresh 手順」
  「禁止例」「watcher 側 safety net との関係」）は構造を保ったまま順序条項を挿入。
- 「watcher 側 safety net との関係」に docs-only auto-refresh も defense-in-depth として
  追記し、Developer から見て両 safety net（fail-with-diagnostic / docs-only auto-refresh）
  の存在意義が一貫して理解できるようにした（Req 4.4: Developer 単体で読んだとき自己完結）。

## 検証結果

- `bash -n local-watcher/bin/issue-watcher.sh` / 全テスト sh ファイル → OK
- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/test/pt_post_marker_classify_test.sh
  local-watcher/bin/modules/*.sh` → 警告ゼロ
- `bash local-watcher/test/pt_post_marker_classify_test.sh` → PASS: 39, FAIL: 0
- 既存隣接テスト 4 件回帰確認（`pt_check_fail_fast_test.sh` 18 PASS /
  `pt_extract_findings_block_test.sh` 20 PASS / `pt_extract_debugger_section_test.sh`
  24 PASS / `normalize_slug_test.sh` 12 PASS）
- `diff -r .claude/agents repo-template/.claude/agents` → 空
- `diff -r .claude/rules repo-template/.claude/rules` → 空

## AC Traceability

| Req | テスト / 実装での担保 |
|---|---|
| 1.1 | test Case A（docs-only + default → rc=0 auto-refresh）+ `pt_classify_post_marker_paths` Case 1-2 |
| 1.2 | test Case A（stderr に `recovery=docs-only-auto-refresh` / `task_id` / `post_marker_shas` 含む） |
| 1.3 | `pt_post_docs_only_auto_refresh_comment` 新設（重複抑制マーカー付き 1 件投稿） |
| 1.4 | test Case A（rc=0 = 続行可能）+ Case B との挙動差で間接的に担保 |
| 1.5 | env `POST_MARKER_DOCS_ALLOWLIST` 既定値の README 明示 + watcher 内コメント |
| 2.1 | test Case 3-4（code/test 含む → mixed） |
| 2.2 | test Case B（mixed + default → rc=5）+ Case 5-7（allowlist 空 / 0 件 / fail-safe） |
| 2.3 | `pt_handle_post_marker_commits` 内の `pt_mark_post_marker_commits_detected` 経路維持 |
| 2.4 | test Case 5（git diff エラー → fail-safe mixed → 上位 fail-with-diagnostic） |
| 3.1 | test Case F（post-marker 0 件 → rc=1） |
| 3.2 | `POST_MARKER_RECOVERY_MODE` の case 文を変更せず（既存 2 値解釈温存） |
| 3.3 | test Case C / D（extend-range は docs-only にオーバーライドされない） |
| 3.4 | test Case E（不正値 → default fallback → docs-only 判定適用 → auto-refresh） |
| 3.5 | env var 名 / ラベル / exit code 意味を変更せず（既存コードベース確認） |
| 4.1-4.4 | `.claude/agents/developer.md` に「順序条項」サブセクション追記（Fix B） |
| NFR 1.1 | README に docs-only auto-refresh 節追記 |
| NFR 1.2 | `diff -r .claude/agents repo-template/.claude/agents` → 空 |
| NFR 1.3 | docs-only auto-refresh / fail-with-diagnostic / extend-range それぞれ単一行ログ |
| NFR 2.1 | 本ノート末尾の merge 後運用 follow-up 参照 |
| NFR 2.2 | `recovery=docs-only-auto-refresh` の単一行 tag を grep 可能 |
| NFR 3.1 | 3 系統 39 アサーションのテスト追加 |
| NFR 3.2 | shellcheck 警告ゼロ / bash -n OK |

## 確認事項

- **allowlist 既定値の妥当性**: Open Questions「`README.md` / `CLAUDE.md` / `.claude/**` の扱い」は
  最小集合（`**/impl-notes.md,docs/specs/**/*.md`）に倒した。運用拡張は env `POST_MARKER_DOCS_ALLOWLIST` で可能。
- **glob `**/impl-notes.md` の挙動**: bash `[[ ]]` 内では `**` は `*` と同等。test Case 8 で root 直下 `impl-notes.md`
  が match しないことを観測。運用上は `docs/specs/<番号>-<slug>/` 配下しかないため実害なし。

## merge 後の運用 follow-up

- **idd-claude watcher cron の暫定 `POST_MARKER_RECOVERY_MODE=extend-range` を撤去できる**。
  本 PR merge 後は default の `fail-with-diagnostic` で動かしても docs-only post-marker commit
  は auto-refresh で救済されるため、暫定運用を維持する必要なし。

STATUS: complete
