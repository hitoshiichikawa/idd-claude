# Implementation Notes (Issue #146)

## 実装サマリ

PM phase（Triage 起動直前）に Issue 本文の前提依存記法（canonical `Depends on:` /
alias `前提依存:` / alias `Blocked by:`）を機械抽出し、各依存先 Issue の `state` と
「Issue を close した PR の merged 状態」を GitHub API から確認、未解決依存が 1 件でも
残る場合は新規追加ラベル `blocked` を付与 + エスカレーションコメント投稿 + claim 系
ラベル除去で人間判断へ委ね、auto-dev pickup を抑止する Dependency Resolver Gate を
追加した。

### タスクごとの変更内容

- **Task 1** (commit `f7b4f91`): `LABEL_BLOCKED="blocked"` 定数を `LABEL_AWAITING_SLOT`
  直後に追加し、`_dispatcher_run` の `gh issue list --search` 既存除外リスト末尾に
  `-label:"$LABEL_BLOCKED"` を追加。既存除外条件の順序・値は不変（NFR 1.3）。
- **Task 2** (commit `03b578a`): `_slug_mismatch_escalate` 直下に Dependency Resolver
  純粋関数群を追加: `dr_log` / `dr_warn` / `dr_error`（既存 `mq_log` / `pi_log` 系と
  同書式 / 識別 prefix `dr:`）、`dr_extract_deps`（POSIX ERE で 3 記法を `grep -E`
  抽出 → `grep -oE '#[0-9]+'` で番号展開 → `sort -u -n` で uniq + 数値昇順）、
  `dr_format_unresolved_comment`（依存未解決専用 markdown 本文を生成、`needs-decisions`
  テンプレ語彙を含めない / Req 9.2）。
- **Task 3** (commit `f748c3e`): `dr_resolve_one`（`gh issue view --json
  state,closedByPullRequestsReferences` を叩き、`jq` で `state` と
  `closedByPullRequestsReferences[].merged` を集計判定して 4 区分文字列を stdout）
  と `dr_apply_block`（`gh issue edit --remove-label claude-claimed --add-label
  blocked` を単一 PATCH で原子的に発行 + `gh issue comment` でエスカレーション本文
  投稿）を追加。`needs-decisions` ラベルには触れない（Req 9.1）。
- **Task 4** (commit `d2889fb`): orchestrator `dr_check_dependencies`（冪等性ガード
  → 依存抽出 → 各依存解決 → 集計 → ブロック付与）を追加し、`_slot_run_issue` の
  `HAS_EXISTING_SPEC=false` かつ `skip-triage` 未付与の `else` 分岐先頭（Triage 起動
  直前）で呼び出す。`impl-resume` および `skip-triage` 経路では呼び出さない（Out of
  Scope: 既に in-flight な Issue への retrofit を避ける）。構造化ログ 1 行を
  `dr: issue=#N extracted=... resolved=... unresolved=... api_errors=... verdict=...`
  形式で出力（Req 6.1 / NFR 2.1〜2.2）。
- **Task 5** (commit `30fdc9c`): self-hosting 用 `.github/scripts/idd-claude-labels.sh`
  と consumer 配布版 `repo-template/.github/scripts/idd-claude-labels.sh` の両系統
  `LABELS` 配列末尾に `"blocked|b60205|【Issue 用】 依存 Issue 未 merge により
  auto-dev 進行不能"` を追加。既存ラベル定義は不変（NFR 1.2）、冪等性は既存ロジックが
  保証（NFR 3.2）。
- **Task 6** (commit `f234b93`): README.md の以下 6 箇所を更新:
  1. Step 2「作成されるラベル」表
  2. Step 2「手動で作成する場合」の `gh label create` 列
  3. 「ラベル状態遷移まとめ」表
  4. ポーリングクエリ例（`-label:blocked` 追加）
  5. ポーリングクエリ説明文（依存記法・運用手順・`needs-decisions` との意味的差分）
  6. 状態遷移図（`claude-claimed` 直下に Dependency Resolver Gate 分岐を追加）
- **Task 7** (本 commit): QUICK-HOWTO.md の「作成されるラベル」インライン列挙に
  `blocked` を追記、最終 shellcheck / bash -n を完走させ本 impl-notes.md を記録。

## 検証結果

### 静的解析

- `bash -n local-watcher/bin/issue-watcher.sh .github/scripts/idd-claude-labels.sh
  repo-template/.github/scripts/idd-claude-labels.sh` — **pass**（3 ファイルすべて
  構文 OK）。
- `shellcheck local-watcher/bin/issue-watcher.sh .github/scripts/idd-claude-labels.sh
  repo-template/.github/scripts/idd-claude-labels.sh` — **新規警告ゼロ**。既存
  SC2317 info（unreachable code、関数を間接呼び出ししているケース）と SC2012 info
  （`ls` 使用箇所、本変更とは無関係な既存箇所）のみが残存。本 Issue で追加した
  関数群（`dr_*`）には警告が発生していない。

### 単体スモークテスト（純粋関数）

`dr_extract_deps` を `/tmp/test-dr-extract.sh` で 7 ケース検証、すべて期待出力:

1. canonical `Depends on: #12 #34` → `12\n34`（昇順 sort 済）
2. alias 日本語 `前提依存: #100` → `100`
3. alias 英語 `Blocked by: #200` → `200`
4. 重複排除 `Depends on: #1\nBlocked by: #1 #2` → `1\n2`
5. 空入力 → 空 stdout（NFR 1.1 / 後方互換）
6. 記法非存在 → 空 stdout
7. カンマ区切り `Depends on: #1, #2, #3` → `1\n2\n3`

`dr_format_unresolved_comment` を 3 区分（open / closed unmerged / api error）の
混在入力で検証し、design.md「Escalation Comment Template」と一致する markdown を
生成することを確認。`needs-decisions` テンプレ語彙を含まないことも確認。

### 単体スモークテスト（orchestrator）

`dr_check_dependencies` を `/tmp/test-dr-check.sh` で 6 シナリオ検証、すべて期待
return code + 構造化ログ:

1. 依存記法なし → `verdict=skip_no_deps` / return 0（NFR 1.1 既存挙動完全互換）
2. 既に blocked 付与済 → 冪等 skip / return 1（Req 3.4 / NFR 3.1）
3. 全件 resolved → `verdict=all_resolved` / return 0（Req 2.6 否定形）
4. 1 件 open → `verdict=blocked` / return 1 / `dr_apply_block` 呼び出し（Req 2.3）
5. closed unmerged + resolved 混在 → `verdict=blocked` / return 1（Req 2.4）
6. api error → `verdict=blocked` / return 1（NFR 4.2 安全側）

### 手動スモークテスト（task 7 (a)(b)(c)）

`auto-dev` 付き Issue を立てて実 watcher サイクルを回す形のスモークテストは、本
worktree 環境では実 `gh` API 呼び出し（依存 Issue 作成 / merge）に伴う副作用が
本 repo に発生してしまうため未実施。代替検証として以下を実施:

- (a) 依存記法非搭載: `dr_check_dependencies` 単体テスト Test 1（記法なし）で
  `verdict=skip_no_deps` / return 0 / 副作用ゼロを確認。`_slot_run_issue` 側でも
  本 gate が return 0 なら Triage に進む構造を確認（コード読み）。
- (b) 依存未解決: `dr_check_dependencies` 単体テスト Test 4 / 5 / 6 で
  `verdict=blocked` / return 1 / `dr_apply_block` 呼び出しを確認。`_slot_run_issue`
  側でも return 1 受領時に `slot_log "依存未解決により blocked 付与（Issue #146）"`
  を残して `return 0` する構造を確認。
- (c) 冪等再評価: 単体テスト Test 2（既に blocked 付与済）で `dr_apply_block` が
  呼ばれず return 1 になることを確認（コメント重複投稿なし）。dispatcher の
  pickup 除外クエリに `-label:"$LABEL_BLOCKED"` を加えたため、`blocked` 手動除去
  後の次サイクルで自動的に再評価される構造を確認（コード読み）。

実 `gh` API を伴う E2E 検証は、self-hosting で次回 cron tick が回るタイミングか
レビュワー判断によって本 PR が main 到達後に dogfooding として実施する想定。

## 確認事項（design.md / tasks.md と既存実装の整合）

- **依存先 Issue の merge 判定フィールド**: design.md / tasks.md は
  `closedByPullRequestsReferences[].merged`（boolean）を使う方針で書かれており、
  `gh issue view --json closedByPullRequestsReferences` の実応答も `merged` boolean
  を含む。本実装は `jq '[.closedByPullRequestsReferences[]? | select(.merged ==
  true)] | length'` で集計判定しており、Optional `?` で空配列にも安全。
  仕様通り。
- **大文字小文字の扱い**: 設計では `Depends on:` / `Blocked by:` を大文字始まりの
  既存運用前提として記述している。本実装は `grep -E` を `-i` なしで使い、
  `(Depends on:|前提依存:|Blocked by:)` の厳密マッチを採用。`depends on:`（小文字始まり）
  はマッチしない。`.claude/rules/issue-dependency.md` の canonical 表記も大文字始まり
  なので整合。
- **action vs. log の語彙**: design.md の Log Schema 例では `unresolved=#150 (open)`
  のような表記を使っており、本実装の構造化ログもこれに準拠。`closed_unmerged` は
  ログ上は `closed_unmerged` で記録（snake_case）、コメント本文上は `closed
  unmerged`（半角スペース）を使う 2 表記を design.md に合わせて使い分けている。
  人間が grep するときには `verdict=blocked` / `verdict=all_resolved` / `verdict=
  skip_no_deps` の 3 区分で集計可能。
- **ポーリングクエリ説明文の依存記法リンク**: README.md の依存記法説明では
  `repo-template/.claude/rules/issue-dependency.md` への相対リンクを採用。
  self-hosting / consumer 配布の双方で参照可能（self-hosting には `repo-template/`
  配下のルールがそのまま配置されているため）。

## Feature Flag Protocol（opt-out 確認）

idd-claude 自身の `CLAUDE.md` の `## Feature Flag Protocol` 節を確認した結果、
**採否は opt-out**（明示宣言なしの fallback と同等）であり、`.claude/rules/feature-flag.md`
の opt-in 採用フローは適用しない。本機能は単一実装パスで実装し、既存挙動との差分は
新規 `blocked` ラベル付与経路の追加に限定。検出パターン非搭載 Issue では gh API
呼び出しゼロ・ラベル変更ゼロ・コメント投稿ゼロで `dr_log` 1 行のみを出力し、本機能
導入前と完全に同一の pickup 挙動を維持（NFR 1.1）。

## 受入基準（AC）の達成確認

requirements.md の numeric ID と本実装でのカバレッジ対応表:

| Requirement | テスト / 検証手段 |
|---|---|
| 1.1 canonical `Depends on:` 抽出 | dr_extract_deps Test 1（canonical）/ dr_check_dependencies Test 3〜5 |
| 1.2 alias 日本語 `前提依存:` 抽出 | dr_extract_deps Test 2（alias 日本語） |
| 1.3 alias 英語 `Blocked by:` 抽出 | dr_extract_deps Test 3（alias 英語）/ dr_check_dependencies Test 6 |
| 1.4 スペース / カンマ区切り複数値 | dr_extract_deps Test 1（スペース）/ Test 7（カンマ） |
| 1.5 重複排除 | dr_extract_deps Test 4（重複） |
| 1.6 検出ゼロ時の skip | dr_extract_deps Test 5, 6（空 stdout）/ dr_check_dependencies Test 1 |
| 1.7 issue-dependency.md と整合 | 検出 3 記法すべてが `.claude/rules/issue-dependency.md` の canonical + alias 表に列挙された記法と一致。コード読みで確認 |
| 2.1 state + closing PR merged 取得 | dr_resolve_one コード読み（`gh issue view --json state,closedByPullRequestsReferences`）+ task 3 commit log |
| 2.2 closed + closing PR merged = resolved | dr_resolve_one コード読み（CLOSED + merged_count>0 → "resolved"） |
| 2.3 open = unresolved | dr_resolve_one コード読み + dr_check_dependencies Test 4 |
| 2.4 closed unmerged = unresolved | dr_resolve_one コード読み + dr_check_dependencies Test 5 |
| 2.5 API エラー = unresolved | dr_resolve_one コード読み（gh 失敗 / jq parse 失敗 → "api error"）+ dr_check_dependencies Test 6 |
| 2.6 1 件でも unresolved ならブロック | dr_check_dependencies Test 4, 5, 6（混在含む） |
| 3.1 `blocked` ラベル付与 | dr_apply_block コード読み + dr_check_dependencies Test 4 で `dr_apply_block` 呼び出し確認 |
| 3.2 エスカレーションコメント 1 件投稿 | dr_apply_block コード読み（gh issue comment 単発）+ dr_format_unresolved_comment スモーク |
| 3.3 claim 系ラベル除去 | dr_apply_block コード読み（`--remove-label "$LABEL_CLAIMED"` 単一 PATCH） |
| 3.4 既に blocked なら冪等 skip | dr_check_dependencies Test 2（冪等 skip） |
| 3.5 後続 Developer / Architect 起動 skip | _slot_run_issue 統合コード読み（`return 0` で当該サイクル早期 return） |
| 3.6 コメント本文に #N + 判定区分 | dr_format_unresolved_comment スモーク出力で確認 |
| 4.1 dispatcher pickup から blocked 除外 | _dispatcher_run の --search に `-label:"$LABEL_BLOCKED"` 追加（task 1 commit） |
| 4.2 手動除去で次サイクル再評価 | 除外クエリが唯一の判定経路（追加 retrofit ロジックなし）+ コード読み |
| 4.3 既存除外ラベルの意味・挙動不変 | _dispatcher_run --search の既存要素順序・値を維持（task 1 diff 確認） |
| 5.1 検出ゼロ時の skip | dr_check_dependencies Test 1 |
| 5.2 検出ゼロ時はラベル/コメント無し | dr_check_dependencies Test 1（副作用ゼロ確認） |
| 5.3 検出ゼロ時の追加処理は本文 parse 1 回のみ | dr_check_dependencies コード読み（gh 呼ばず dr_extract_deps 1 回のみ） |
| 6.1 構造化ログ出力 | dr_check_dependencies の `dr_log` 経路、全 6 スモークケースで `verdict=...` 出力確認 |
| 6.2 API 失敗時の理由ログ | dr_resolve_one の `dr_warn` 出力（gh stderr / jq エラー） |
| 6.3 LOG_DIR 配下に出力 | dr_log は既存 dispatcher_log / slot_log と同じ stdout/tee 経路（コード読み） |
| 7.1 一括ラベル作成スクリプトで blocked を作成 | .github/scripts/idd-claude-labels.sh LABELS 配列に追加（task 5 diff） |
| 7.2 description に意味を含める | "【Issue 用】 依存 Issue 未 merge により auto-dev 進行不能" |
| 7.3 description prefix 【Issue 用】 | self-hosting 側で prefix 採用、consumer 側も同 prefix で整合（task 5 diff） |
| 7.4 既存 + force なし = skip | 既存ロジックそのまま（NFR 3.2） |
| 7.5 既存 + force = 上書き更新 | 既存ロジックそのまま（NFR 3.2） |
| 7.6 self-hosting 用 + consumer 用に同一定義 | 両ファイルとも同じ `"blocked|b60205|..."` を追加（task 5 diff） |
| 8.1 README ラベル一覧に blocked 追記 | README Step 2 表に追加（task 6 diff） |
| 8.2 README 状態遷移節で pickup 除外を記述 | README ポーリングクエリ + 説明文（task 6 diff） |
| 8.3 README 運用フローで依存記法を説明 | README ポーリングクエリ説明文に依存記法 + .claude/rules/issue-dependency.md リンク（task 6 diff） |
| 8.4 README 解消手順を明示 | README 説明文「依存先を merge → blocked 手動除去 → 次 cron tick で再評価」（task 6 diff） |
| 8.5 blocked と needs-decisions の意味的差分 | README 説明文（task 6 diff） |
| 8.6 QUICK-HOWTO のラベル列挙に追記 | QUICK-HOWTO.md 行 72-74 のインライン列挙に追加（task 7 diff） |
| 9.1 blocked 付与時に needs-decisions を付与しない | dr_apply_block コード読み（`--add-label "$LABEL_BLOCKED"` のみ） |
| 9.2 エスカレーションコメントが needs-decisions テンプレと混在しない | dr_format_unresolved_comment スモーク出力（依存未解決専用文面） |
| 9.3 dispatcher は両ラベルを独立に除外 | _dispatcher_run --search で `-label:"needs-decisions"` と `-label:"blocked"` を並列指定（task 1 diff） |
| 9.4 README が両ラベルを別ラベルとして列挙 | README 説明文（task 6 diff） |
| NFR 1.1 検出ゼロ時に既存挙動と完全一致 | dr_check_dependencies Test 1（副作用ゼロ）+ コード読み |
| NFR 1.2 既存ラベル定義不変 | task 5 diff で既存行未変更を確認 |
| NFR 1.3 dispatcher 既存除外条件不変 | task 1 diff で既存要素順序・値の維持を確認 |
| NFR 1.4 コードフェンス内誤検出は運用許容 | dr_extract_deps が markdown context を解析しないことを設計判断として明文化（design.md / コード読み） |
| NFR 2.1 構造化ログで grep 可能 | `dr: issue=#N extracted=... verdict=...` 形式の 1 行ログ |
| NFR 2.2 LOG_DIR 配下に記録 | dr_log は既存 stdout/tee 経路に乗る |
| NFR 3.1 N 回再実行で 1 個に収束 | dr_check_dependencies Test 2（冪等 skip） |
| NFR 3.2 labels.sh の再実行冪等性 | 既存ロジックが既に冪等 |
| NFR 4.1 Triage 時間に対して支配的にならない | 通常 1〜3 件の依存で gh issue view 数回（数秒）、cron tick (2 分) 内に収まる設計 |
| NFR 4.2 rate limit 抵触時は安全側 = blocked 扱い | dr_resolve_one の "api error" 経路 + dr_check_dependencies Test 6 |

## STATUS

STATUS: complete
