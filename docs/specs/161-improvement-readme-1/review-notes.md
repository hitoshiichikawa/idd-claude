# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T10:25:00Z -->

## Reviewed Scope

- Branch: claude/issue-161-impl-improvement-readme-1
- HEAD commit: 2f8be34b5779f024dbd34d966949fab26d2f6674
- Compared to: main..HEAD
- 変更ファイル: `README.md`（+31 / -23 行）/ `docs/specs/161-improvement-readme-1/impl-notes.md`（新規 185 行）
- 性質: README.md の文書改訂のみ（env var / コード変更なし）。Feature Flag Protocol 採否は
  CLAUDE.md に `## Feature Flag Protocol` 節が無いため **opt-out として解釈** → flag 観点の
  追加チェックは適用外

## Verified Requirements

- 1.1 — README L1107-1108 / L1123-1124 で 2 表の列ヘッダに「正規化規則」「追加 env（必須/推奨）」「詳細」を追加。各行に併記済み
- 1.2 — 必須追加 env が無い行は `—`（em dash）で明示（L1110-1114, L1117, L1131-1132 等）。空欄は不使用
- 1.3 — Phase B 行 L1125 で `**必須**: ST_CHECK_RUN_NAME` を強調表示し、サイレント skip を回避する env 群を 1 行で読み取れる
- 1.4 — 「デフォルト有効」（11 行）「opt-in」（8 行）両表に同じ列構造で適用
- 1.5 — Feature Flag Protocol 行（L1131）/ GitHub Actions 行（L1132）で「制御変数」セルに「**env var ではない**」を明記、追加 env 列は `—`
- 2.1 — 全行に「正規化規則」列が存在（L1109-1119 / L1125-1132）
- 2.2 — デフォルト有効 11 行全てに「`=false` 厳密一致のみ無効。それ以外（空文字 / `0` / `False` / typo）はすべて有効」を併記。`IMPL_RESUME_PRESERVE_COMMITS` のみ既存表記（`Yes` / `1` / 空文字 / typo / 不正値）に整合させて温存
- 2.3 — Phase B / D / E / 2 / 3 の 5 行で「厳密一致する文字列」と「それ以外は OFF / `false` 等価」を明示（L1125, 1127, 1128, 1129, 1130）
- 2.4 — Phase B 行に「サイレント skip」、Phase D 行に「`MECHANICAL_PATHS` 空時の全件 semantic 扱い」、impl-resume 進捗追跡行に「`IMPL_RESUME_PRESERVE_COMMITS=false` 時の no-op」を併記
- 3.1 — Phase B 行 L1125 で `ST_CHECK_RUN_NAME` を **必須** ラベル付きで明示
- 3.2 — Phase D 行 L1127 で「`=claude` 厳密一致のみ有効。それ以外（未設定 / `off` / `on` / `true` / 大文字小文字違い / typo）はすべて OFF」を明示
- 3.3 — Phase E 行 L1128 で「`=true` 厳密一致のみ有効。それ以外（未設定 / `off` / `on` / `1` / `True` / 大文字小文字違い / typo）はすべて OFF」を明示
- 3.4 — Phase 2 行 L1129 で `PER_TASK_MAX_TASKS` を暴走防止 knob として明示
- 3.5 — Phase 3 行 L1130 で `DEBUGGER_MODEL` / `DEBUGGER_MAX_TURNS` を任意 knob として明示
- 4.1 — 全行で「詳細」列の anchor link を維持（既存 anchor `#promote-pipeline-processor-phase-b` 等を変更せず）
- 4.2 — 詳細セクションの正本性は維持（L1383 `ST_CHECK_RUN_NAME` 完全仕様 / L1509 `AUTO_REBASE_MODE` / L1636 `PATH_OVERLAP_CHECK` / L3422 `PER_TASK_MAX_TASKS` / L3563-3564 `DEBUGGER_*` を確認）
- 4.3 — Migration Note (#161) L1097-1103 で「一覧表と詳細セクションの記述が食い違っている場合は **詳細セクションを正本** として読んでください」を明示
- 4.4 — 「常時有効（opt-out 不可）」表 L1152-1158 / 「`install.sh` の runtime フラグ（参考）」表 L1161-1168 は無変更
- 5.1 — README 文書改訂のみ。`local-watcher/bin/issue-watcher.sh` その他コード変更なし（`git diff --stat` で確認）
- 5.2 — 既存 anchor は変更なし（詳細セクション側の見出し ID は無編集）
- 5.3 — 表直前 L1097-1103 に新規 1 段落の Migration Note (#161) を追加し、列構造変更の意図を明示
- NFR 1.1 — 「有効化キー」「必須追加 env」「正規化規則」は一覧表内で 1 度ずつ記述。別表・別節への重複定義なし
- NFR 1.2 — Migration Note (#161) で「各 env の完全仕様（既定値・許容値範囲・ログ識別語）は引き続き Phase 別詳細セクションが正本」を宣言
- NFR 1.3 — Migration Note (#161) で食い違い時の正本判定を明示
- NFR 2.1 — 1 機能 1 行の構造を維持（行の縦分割なし）
- NFR 2.2 — 既存 cron 最小例（L1139-1142）/ 個別無効化例（L1146-1150）を温存
- NFR 3.1 — 説明文は日本語、env var 名 / 値リテラル（`true` / `false` / `claude` / `=true` 等）は英語固定
- NFR 3.2 — EARS トリガーキーワード（`When` / `If` / `While` / `Where` / `shall`）は本文に混入していない

## Findings

なし

## Summary

README.md の 2 表（L1107-1119 デフォルト有効 11 行 / L1123-1132 opt-in 8 行）に「正規化規則」
「追加 env（必須/推奨）」列を追加し、表直前に Migration Note (#161) を新設。Issue #161 が
例示した 4 件のサイレント失敗事故（`ST_CHECK_RUN_NAME` 未設定で Phase B skip / `AUTO_REBASE_MODE=on`
の OFF 正規化 / `PATH_OVERLAP_CHECK` の `=true` 厳密一致 / `PER_TASK_MAX_TASKS` 周知）が
一覧表だけで防げる状態に到達している。詳細セクションの正本性 / 既存 anchor / 「常時有効」表 /
`install.sh` フラグ表 / 既存 cron 例ブロックも全て保持され、後方互換性も満たす。boundary 逸脱
なし、env var / コード変更なしのためテスト追加も不要。

RESULT: approve
