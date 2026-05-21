# Requirements: Phase E — Triage path overlap 検知（hot file 競合予防）

## Issue

- Issue: #18
- Title: Phase E: Triage path overlap 検知（hot file 競合予防）
- 親: #13
- 依存: #16（Phase C 並列化, merged）
- 関連: #14（Phase A）/ #15（Phase B Promote pipeline）/ #17（Phase D）/ #27

## Overview

複数 Issue を slot 並列で同時開発する運用では、`package.json` や共通 util など、複数 Issue が
触りやすい hot file 上で merge conflict が頻発する。Phase A（自動 rebase）と Phase D（semantic
解析）で出口側の自己修復は既に整備されているが、本フェーズでは入口側で予防する。

Triage 段階で Claude に当該 Issue が編集する見込みの top-level path を列挙させ、Dispatcher が
slot に投入する直前に in-flight な他 Issue の編集見込みパスと突合する。重複があれば
`awaiting-slot` ラベルを付与して dispatch を見送り、先行 Issue の PR が merge されて in-flight
集合から外れた次サイクルで自然に再開する。

本機能は **opt-in（`PATH_OVERLAP_CHECK=true` で有効化、既定 `off`）** で、未指定／`false` の
場合は本機能導入前と挙動が完全一致する。対象ユーザーは Dispatcher を運用する idd-claude 利用
者（cron / watcher のオペレーター）であり、複数 Issue 並列処理時の conflict 復旧コストを下げる
ことが価値となる。

## Requirements

### Requirement 1: opt-in gate と後方互換性

本機能は環境変数で明示的に有効化したときのみ動作し、未設定環境では本機能導入前と完全に同一の
挙動を保つ。

#### Acceptance Criteria

- 1.1 The Path Overlap Checker shall be enabled only when `PATH_OVERLAP_CHECK` environment variable is set to the literal string `true`.
- 1.2 If `PATH_OVERLAP_CHECK` is unset, the Path Overlap Checker shall not execute any new logic and the Dispatcher shall behave identically to the pre-Phase-E baseline.
- 1.3 If `PATH_OVERLAP_CHECK` is set to any value other than `true`（例: `false` / 空文字列 / `True` / `1` / その他 typo）, the Path Overlap Checker shall not execute any new logic and the Dispatcher shall behave identically to the pre-Phase-E baseline.
- 1.4 The default value of `PATH_OVERLAP_CHECK` shall be treated as `off` even if the variable is not declared in the watcher environment.

### Requirement 2: Triage 出力スキーマの additive 拡張

Triage Agent は Issue ごとに編集見込み path 配列を返し、watcher 側のスキーマは additive に拡張
される。既存 Triage 結果スキーマの後方互換を壊さない。

#### Acceptance Criteria

- 2.1 Where `PATH_OVERLAP_CHECK` is `true`, the Triage Agent shall include a JSON array field representing top-level edit paths in its Triage output for the target Issue.
- 2.2 The edit paths array shall contain top-level path entries（ディレクトリまたはファイル単位）, expressed as repository-root relative path strings.
- 2.3 If the Triage Agent cannot infer any edit path with confidence, the Triage Agent shall emit an empty array rather than omitting the field or emitting a non-array value.
- 2.4 If the edit paths field is absent in a Triage result（旧スキーマで生成された既存 Issue 等）, the Path Overlap Checker shall treat the value as an empty array and continue gracefully without erroring.
- 2.5 The Triage output schema change shall be additive only and shall not alter the existing `status` / `needs_architect` / `architect_reason` / `rationale` / `decisions` fields' presence, type, or semantics.

### Requirement 3: 編集見込みパスの永続化

Triage が出力した編集見込み path 配列を、watcher が後続サイクルで安定的に再読でき、かつ運用者
が GitHub UI 上で目視確認できる形で Issue に永続化する。

#### Acceptance Criteria

- 3.1 Where `PATH_OVERLAP_CHECK` is `true`, the Path Overlap Persister shall store the Triage edit paths array on the target Issue in a location that is re-readable by subsequent watcher cron ticks.
- 3.2 The persisted edit paths shall be human-visible on the GitHub Issue page without requiring access to local watcher logs.
- 3.3 When the Triage Agent re-runs for the same Issue（例: needs-decisions 解消後の再 Triage）, the Path Overlap Persister shall overwrite the previously persisted edit paths with the latest value rather than appending duplicate records.
- 3.4 If persistence of edit paths fails（API 失敗 / レート制限 / 権限不足等）, the Path Overlap Persister shall log the failure and shall not block the surrounding Triage success path（Triage 全体は成功扱い、overlap check は次サイクルで再評価される fail-open 方針）.

### Requirement 4: in-flight 集合の定義

Path Overlap Checker が突合対象とする「in-flight Issue 集合」は label の有無で機械的に定義され、
集合に属するラベルは Issue 本文に列挙されたもののみとする。

#### Acceptance Criteria

- 4.1 The Path Overlap Checker shall treat an Issue as in-flight if and only if it carries at least one of the following labels: `claude-claimed`, `claude-picked-up`, `awaiting-design-review`, `ready-for-review`, `needs-iteration`, `needs-rebase`, `staged-for-release`.
- 4.2 The Path Overlap Checker shall not include Issues carrying `st-failed` or `awaiting-slot` as in-flight members（候補 Issue 自身を含む）.
- 4.3 The Path Overlap Checker shall exclude the candidate Issue currently being evaluated from its own in-flight comparison set.
- 4.4 When evaluating in-flight members, the Path Overlap Checker shall consider only Issues from the same repository as the candidate Issue.

### Requirement 5: Overlap 判定と dispatch 抑止

Dispatcher が candidate Issue を slot に割り当てる前段で in-flight 集合との path overlap を判定
し、重複があれば dispatch を抑止する。重複なしなら従来通り dispatch する。

#### Acceptance Criteria

- 5.1 Where `PATH_OVERLAP_CHECK` is `true`, the Path Overlap Checker shall compute the intersection of the candidate Issue's edit paths and the union of in-flight Issues' edit paths before the Dispatcher hands the candidate to a slot.
- 5.2 If the intersection is non-empty, the Path Overlap Checker shall add the `awaiting-slot` label to the candidate Issue and shall prevent the Dispatcher from dispatching the candidate in the current cron tick.
- 5.3 If the intersection is non-empty, the Path Overlap Checker shall post a comment on the candidate Issue explaining which path（s） caused the deferral and which in-flight Issue（s） are holding those paths.
- 5.4 If the intersection is empty, the Path Overlap Checker shall not add the `awaiting-slot` label and the Dispatcher shall proceed with normal dispatch.
- 5.5 When the candidate Issue has no persisted edit paths（旧 Issue 等 / Req 2.4 適用ケース）, the Path Overlap Checker shall treat the candidate's edit paths as empty and shall not block dispatch on that basis alone.
- 5.6 The path comparison shall be performed at top-level granularity（ディレクトリまたはファイル単位）and shall not attempt sub-path or AST-level overlap analysis.

### Requirement 6: `awaiting-slot` 自然解消

先行 Issue の PR が merge されて in-flight 集合から外れた次サイクルで、`awaiting-slot` ラベル
は自動的に外れ、対象 Issue は通常 dispatch に戻る。

#### Acceptance Criteria

- 6.1 While the candidate Issue carries `awaiting-slot`, when the Path Overlap Checker re-evaluates in a later cron tick, the Path Overlap Checker shall recompute the overlap against the current in-flight set.
- 6.2 If the recomputed overlap is empty, the Path Overlap Checker shall remove the `awaiting-slot` label from the candidate Issue and the Dispatcher shall proceed with normal dispatch in the same cron tick.
- 6.3 While the recomputed overlap remains non-empty, the Path Overlap Checker shall keep the `awaiting-slot` label and shall not dispatch the candidate.
- 6.4 The Path Overlap Checker shall not require human intervention to remove `awaiting-slot` in the natural-resolution path（先行 PR merge → in-flight 集合縮小）.

### Requirement 7: ラベル定義の追加

`awaiting-slot` ラベルは idd-claude の標準ラベル定義スクリプトに追加され、既存ラベルと同じ
色彩規約・description 規約に従う。

#### Acceptance Criteria

- 7.1 The label provisioning script shall define `awaiting-slot` as a known idd-claude label, using a color value and description text consistent with the surrounding label entries in the same script.
- 7.2 When the label provisioning script is re-run idempotently on a repository that already has `awaiting-slot`, the script shall not fail and shall not destructively modify the existing label.
- 7.3 The label provisioning script shall not remove or rename any existing label entry as part of this change（追加のみ）.

### Requirement 8: Observability（ログ規約）

overlap 検出・`awaiting-slot` 付与・除去はすべて watcher のログ出力で観測可能でなければならず、
既存 watcher のログ形式と整合する。

#### Acceptance Criteria

- 8.1 When the Path Overlap Checker detects a non-empty overlap, the Path Overlap Checker shall emit a log line that contains the `[$REPO]` prefix, the candidate Issue number, the overlapping path（s）, and the holder in-flight Issue number（s）.
- 8.2 When the Path Overlap Checker adds the `awaiting-slot` label, the Path Overlap Checker shall emit a log line that contains the `[$REPO]` prefix and the candidate Issue number.
- 8.3 When the Path Overlap Checker removes the `awaiting-slot` label, the Path Overlap Checker shall emit a log line that contains the `[$REPO]` prefix and the candidate Issue number.
- 8.4 The Path Overlap Checker shall write the log lines defined in 8.1–8.3 to the same destination as existing dispatcher / mq / pi / drr log streams（cron.log 経路）.

### Requirement 9: README ドキュメント更新

idd-claude README に Phase E の節を追加し、有効化方法・観測ログ・自然解消の挙動を運用者が
セルフサービスで理解できる粒度で記述する。

#### Acceptance Criteria

- 9.1 The README shall include a section titled in a way that identifies it as Phase E（path overlap 検知 / hot file 競合予防）.
- 9.2 The README section shall describe how to opt in（`PATH_OVERLAP_CHECK=true` の設定方法）and that the default is off.
- 9.3 The README section shall enumerate the in-flight labels listed in Requirement 4.1 so that operators can predict what triggers deferral.
- 9.4 The README section shall describe the natural-resolution path（先行 PR merge → 次サイクルで `awaiting-slot` が自動除去 → dispatch 再開）.

### Requirement 10: Dogfood test 手順

idd-claude 自身を対象に手動で E2E 検証を実施し、本機能が想定通り動作することを Issue 完了時に
観測可能にする。

#### Acceptance Criteria

- 10.1 The dogfood test procedure shall instruct the operator to set `PATH_OVERLAP_CHECK=true` in the idd-claude watcher environment.
- 10.2 The dogfood test procedure shall instruct the operator to file two auto-dev Issues that both edit the same watcher source file concurrently.
- 10.3 When the dogfood test procedure is executed under the conditions of 10.1 and 10.2, the later Issue shall acquire the `awaiting-slot` label and shall not be dispatched while the earlier Issue is in-flight.
- 10.4 When the earlier Issue's PR is merged and it leaves the in-flight set, the later Issue's `awaiting-slot` label shall be removed and the later Issue shall be dispatched in a subsequent cron tick without manual intervention.

### Requirement 11: Pre-merge 静的検査

本機能の変更ファイルに対して既存の静的検査ツールが警告ゼロで通過すること。

#### Acceptance Criteria

- 11.1 The `shellcheck` invocation on `local-watcher/bin/issue-watcher.sh` shall complete with zero warnings after the Phase E changes are applied.

### Requirement 12: Dispatcher 性能影響の制約

本機能は Dispatcher の 1 cron tick あたりの処理時間に有意な悪化を与えないこと。

#### Acceptance Criteria

- 12.1 For each candidate Issue evaluated by the Path Overlap Checker, the Path Overlap Checker shall consume at most one read of the persisted edit paths and one label set comparison per candidate（追加の N+1 GitHub API fetch を発生させない）.
- 12.2 The Path Overlap Checker shall not introduce additional per-candidate GitHub API calls beyond those defined in 12.1 when no overlap is detected.

## Non-Goals

- overlap 判定の高精度化（AST レベル / 関数単位の diff 解析） — 将来課題
- 編集 path の推定を Claude ではなく静的解析（言語別 dependency graph 等）で行う方式 — 将来課題
- `staged-for-release` を in-flight 集合に含めるかどうかの最終確定 — Phase B（#15）着手結果と
  歩調を合わせる。本フェーズでは Requirement 4.1 の通り **含める** 方針で固定し、変更が必要
  になれば別 Issue で再検討する
- fork PR に対する overlap 判定 — fork PR は Dispatcher の処理対象外（既存方針継承）
- Triage prompt schema の明示的なバージョニング（schema version 番号の付与） — additive 拡張と
  key 存在チェックでの graceful degrade で代替する
- 外部 Feature Flag SaaS（LaunchDarkly / Unleash 等）連携 — opt-in は env var のみで完結

## 確認事項

- **edit_paths の永続化方式**: Issue 本文「未解決の設計論点」では sticky comment + hidden marker
  が推奨されている。Requirement 3 では「watcher が再読可能かつ Issue ページで目視可能」という
  observable な要件に留めているため、最終的な保存方式（sticky comment / hidden marker /
  Issue body 編集 / 別ストア）の確定は Architect の design.md に委ねる。
- **`staged-for-release` の扱い**: Requirement 4.1 で in-flight に含める方針で固定したが、
  Phase B（#15）の運用結果次第で除外側に倒す判断もあり得る。本 Issue 着手中に Phase B 側で
  決定が更新された場合は、人間にエスカレーションして要件を更新する。
- **overlap コメントの sticky 化**: Requirement 5.3 では「コメントを post する」とのみ規定して
  いるが、cron tick 毎にコメントが累積すると Issue ノイズが増える懸念がある。sticky 化（hidden
  marker で同一コメントを edit する）を採用するかは Architect 判断に委ねる。
