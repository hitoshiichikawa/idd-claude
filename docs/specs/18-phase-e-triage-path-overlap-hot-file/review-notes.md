# Review Notes

<!-- idd-claude:review round=2 model=claude-opus-4-7 timestamp=2026-05-21T14:30:00Z -->

## Reviewed Scope

- Branch: claude/issue-18-impl-phase-e-triage-path-overlap-hot-file
- HEAD commit: c8b37af2d55f159dd7c0b7c7d430fdcb5a99880b
- Compared to: main..HEAD
- Files changed (against main):
  - `local-watcher/bin/triage-prompt.tmpl` (+20)
  - `local-watcher/bin/issue-watcher.sh` (+597)
  - `repo-template/.github/scripts/idd-claude-labels.sh` (+1)
  - `README.md` (+132)
  - `docs/specs/18-phase-e-triage-path-overlap-hot-file/tasks.md` (進捗マーカー更新)
  - `docs/specs/18-phase-e-triage-path-overlap-hot-file/impl-notes.md`（新規）
- Round 2 主要差分: 92d42d0 `fix(watcher): holders 情報を overlap comment / log に含める`
  + c8b37af `docs(spec): #18 round 2 是正対応セクションを impl-notes に追記`
- Feature Flag Protocol: 対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節での
  `**採否**: opt-in` 宣言なし → 既定 opt-out として通常の 3 カテゴリ判定のみで評価

## Round 1 Findings の是正確認（重点）

### Round 1 Finding 1 (Req 5.3) — 解消済

- Round 1 指摘: `po_apply_awaiting_slot` が overlap path のみで holders を受け取らず、
  sticky comment 本文に「どの in-flight Issue が path を保持しているか」が記載されていない
- Round 2 是正:
  - `po_collect_inflight_issues` の戻り値スキーマを `{"union": [...], "holders": {path: [issue#, ...]}}`
    の JSON object に拡張（issue-watcher.sh:2310-2360）。同関数内の既存
    `po_load_edit_paths` ループ内で union と holders map を同時構築するため、
    API 呼び出し回数は変わらず Req 12.1 を維持
  - 新規 `po_resolve_overlap_holders` 関数を追加（issue-watcher.sh:2375）。holders map
    の生キーに既存 `normalize` 規約（先頭 `./` 剥がし / 連続スラッシュ圧縮 / top-level
    セグメント + `/`）を適用してから overlap path と突合し bucket 化
  - 新規 `po_format_holders_table_md` 関数を追加（issue-watcher.sh:2431）。
    `| 重複 path | 保持中の Issue |` 形式の md 表を生成（design.md L855-863 準拠）
  - `po_apply_awaiting_slot` の第 3 引数として `holders_map_json` を追加
    （issue-watcher.sh:2509）。指定時は holders 表でレンダリング、未指定 / 空 map
    時は従来の path md リストにフォールバック（後方互換）
  - `po_check_dispatch_gate` の overlap 検出パスで `po_resolve_overlap_holders` →
    `po_format_holders_for_log` → `po_apply_awaiting_slot` に holders map を伝播
    （issue-watcher.sh:2641-2660）

### Round 1 Finding 2 (Req 8.1) — 解消済

- Round 1 指摘: overlap 検出ログ行に `holders=#<N>,#<M>` フィールドが欠落
- Round 2 是正:
  - 新規 `po_format_holders_for_log` 関数を追加（issue-watcher.sh:2411）。
    overlap-holders map から `#39,#40` 形式の unique sort 済 flat 文字列を生成
  - `po_check_dispatch_gate` の overlap 検出ログ行を
    `po_log "overlap detected candidate=#${candidate} paths=${paths_for_log} holders=${holders_for_log}"`
    に変更（issue-watcher.sh:2650）。holders が空（in-flight 直前 close 等の race）の
    場合は `holders=-` で明示的に欠落を記録（issue-watcher.sh:2654、fail-open）

## Verified Requirements

- 1.1 — `po_check_dispatch_gate` 冒頭の `[ "$PATH_OVERLAP_CHECK" = "true" ] || return 0`（issue-watcher.sh:2613）
- 1.2 — 同上の早期 return + dispatcher candidate query 不変
- 1.3 — `True` / `1` / 空文字 / typo はすべて厳密一致で外れて off 扱い。impl-notes Smoke (env normalize) で 9 ケース PASS
- 1.4 — `PATH_OVERLAP_CHECK="${PATH_OVERLAP_CHECK:-off}"`
- 2.1 — `triage-prompt.tmpl` の出力 JSON schema 例示ブロックに `"edit_paths": [ ... ]` 追記
- 2.2 — prompt 内「ディレクトリは末尾 `/` 付き、ファイルは `/` なし」「top-level（1 段目）のみ」明記
- 2.3 — prompt 内「確信が持てない場合は空配列 `[]` を返してください（omit や null は不可）」明記
- 2.4 — `po_parse_triage_edit_paths` の `.edit_paths // []` + `if type == "array"` ガード
- 2.5 — 既存 5 keys（status / needs_architect / architect_reason / rationale / decisions）の prompt 指示と jq 抽出は不変
- 3.1 — `po_persist_edit_paths`（sticky comment, marker `<!-- idd-claude:edit-paths:v1 -->`）+ `po_load_edit_paths`
- 3.2 — sticky comment 本文に人間可読 md リスト
- 3.3 — `po_persist_edit_paths` 内で既存 marker 持ち comment id を抽出 → `gh api -X PATCH` で上書き
- 3.4 — `_slot_run_issue` 内の `po_persist_edit_paths || po_warn`（warn のみで Triage 全体は成功扱い継続）
- 4.1 — `po_collect_inflight_issues` の `--search` に 7 ラベル OR を列挙（issue-watcher.sh:2319）
- 4.2 — 同 `--search` に `-label:"st-failed" -label:"awaiting-slot"` を明示
- 4.3 — `if [ "$n" = "$candidate" ]; then continue; fi`（issue-watcher.sh:2337-2339）
- 4.4 — `gh issue list --repo "$REPO"` 固定
- 5.1 — `_dispatcher_run` 内、`check_existing_impl_pr` 通過後・`_dispatcher_find_free_slot` 前で `po_check_dispatch_gate` を呼ぶ
- 5.2 — `po_apply_awaiting_slot` でラベル付与 + `po_check_dispatch_gate` の `return 1` で dispatch skip
- 5.3 — **round 2 で是正**: sticky comment 本文に `| 重複 path | 保持中の Issue |` 表
  （`po_format_holders_table_md` 経由）。`po_check_dispatch_gate` から
  `po_apply_awaiting_slot` へ holders_map_json を伝播（issue-watcher.sh:2657）
- 5.4 — `po_check_dispatch_gate` 末尾の `return 0`（claim 続行）
- 5.5 — `po_compute_overlap` の jq で candidate 空配列なら結果も空、smoke test (b)(c)(d)(e)(h) PASS
- 5.6 — `po_compute_overlap` の `normalize` jq def（先頭セグメント + `/`）
- 6.1 — candidate query に `awaiting-slot` 除外を追加していない
- 6.2 — overlap empty かつ has_awaiting 真のとき `po_clear_awaiting_slot` 呼び出し → `return 0`
- 6.3 — overlap non-empty のとき `po_clear_awaiting_slot` は呼ばれず、return 1 で dispatch skip
- 6.4 — clear + claim 続行を同サイクル内で完結（人間介入不要パス）
- 7.1 — `idd-claude-labels.sh` の LABELS 配列末尾に `awaiting-slot|c5def5|...` 1 行追加
- 7.2 — 既存 `EXISTING_LABELS_JSON` チェックロジックで自動的に冪等
- 7.3 — 既存 13 行（auto-dev 〜 st-failed）の name / color / description は無変更
- 8.1 — **round 2 で是正**: overlap 検出ログ行に `holders=#<N>,#<M>` 形式（または欠落時 `holders=-`）を追記。
  `po_format_holders_for_log` 経由で unique sort 済 flat 文字列を生成（issue-watcher.sh:2650, 2654）
- 8.2 — `po_apply_awaiting_slot` 内 `po_log "awaiting-slot added candidate=#${issue_number}"`
- 8.3 — `po_clear_awaiting_slot` 内 `po_log "awaiting-slot cleared candidate=#${issue_number} (overlap empty)"`
- 8.4 — `po_log` / `po_warn` は stdout / stderr 経由で既存 `pp_log` 等と同経路（cron.log にリダイレクト）
- 9.1 — README に `## Path Overlap Checker (Phase E)` 独立節を追加
- 9.2 — README 同節「環境変数」サブセクション + cron 例で `PATH_OVERLAP_CHECK=true` の opt-in 方法を記述
- 9.3 — README 同節「in-flight 集合の定義」で Req 4.1 の 7 ラベルを箇条書き列挙
- 9.4 — README 同節「自然解消の流れ」で 4 ステップ説明
- 10.1〜10.4 — README「dogfood 確認手順」 + impl-notes.md「Dogfood E2E 手順」に Req 10.1〜10.4 の AC 文言を再録した運用者向け手順を記載（実機実行は人間に委ねる方針が明記済み）
- 11.1 — impl-notes に shellcheck `local-watcher/bin/issue-watcher.sh` および `idd-claude-labels.sh` で出力なし / exit 0 の記録。round 2 でも `shellcheck -S warning` 再実行で warnings ゼロ維持を確認
- 12.1 — round 2 拡張後も candidate あたり API 呼び出し回数は不変（既存 `po_load_edit_paths` ループ内で holders map を同時構築するため追加 fetch なし）。impl-notes に明記
- 12.2 — overlap empty かつ has_awaiting なしのとき `po_check_dispatch_gate` は `gh issue edit` / `gh issue comment` を発火しない

## Boundary 違反確認

- tasks.md の `_Boundary:_` で許可された全境界（Triage Prompt Template / Label Provisioning
  Script Edit / Path Overlap Env Resolver / Path Overlap Logger / Triage Edit-Paths Parser /
  Path Overlap Persister / In-Flight Collector / Overlap Engine / Awaiting Slot State
  Machine / Dispatcher Integration Point / Awaiting Slot Re-evaluator / README Section /
  Static Check Procedure / Dogfood Test Procedure）に収まる変更のみ
- 変更ファイルは design.md File Structure Plan の Modified Files 4 件（`triage-prompt.tmpl` /
  `issue-watcher.sh` / `idd-claude-labels.sh` / `README.md`）+ spec docs
  （`tasks.md` 進捗マーカー / `impl-notes.md` 新規）
- Out-of-scope ファイル（`install.sh` / `setup.sh` / `.github/workflows/*` /
  `repo-template/.claude/agents/*` / `repo-template/.claude/rules/*`）への変更なし
- 境界逸脱なし

## Missing Test 確認

- 本リポジトリには unit test フレームワークがなく（CLAUDE.md 「テスト規約」参照）、
  検証は静的解析 + 手動スモークテストの組み合わせで実施する規約
- impl-notes.md「静的検査・スモーク結果（task 8 実施記録）」+「Smoke Test 結果（round 2）」に:
  - `shellcheck -S warning` exit 0 / 出力 0 行（Req 11.1）
  - `bash -n` syntax OK
  - round 1 既存 23 ケース regression（`po_parse_triage_edit_paths` 6 件 / `po_compute_overlap` 8 件 /
    env normalize 9 件）が全 PASS のまま維持
  - round 2 新規 holders 伝播 smoke test 16 ケース全 PASS（`po_resolve_overlap_holders` /
    `po_format_holders_for_log` / `po_format_holders_table_md` の入出力テーブル検証）
  - round 2 新規 `po_collect_inflight_issues` 集約ロジック smoke test 6 ケース全 PASS
    （union + holders map 同時構築の正当性検証）
  - dry run smoke（`PATH_OVERLAP_CHECK=off` / `=true` candidate=0）で `path-overlap:` ログ 0 行
- 各検証は対応する AC ID を traceability 表に明記済み
- missing test なし

## Findings

なし（round 1 で reject した Finding 1 / 2 はいずれも round 2 で解消された）

## Summary

Round 1 で reject した 2 件の AC 未カバー（Req 5.3 / Req 8.1 の holders 表示）は、round 2
コミット 92d42d0 で適切に是正された。`po_collect_inflight_issues` の戻り値を
`{union, holders}` の JSON object に拡張する設計選択により、追加 API call を発生させずに
（Req 12.1 維持）holders 情報を取得・伝播する流れが整っている。sticky comment 本文には
design.md L855-863 準拠の `| 重複 path | 保持中の Issue |` 表が表示され、log 行には
`holders=#<N>,#<M>` フィールドが追記される（holders 空時は `holders=-` で fail-open）。
全 12 Requirement / 53 AC をカバーし、boundary 逸脱・missing test なし。

RESULT: approve
