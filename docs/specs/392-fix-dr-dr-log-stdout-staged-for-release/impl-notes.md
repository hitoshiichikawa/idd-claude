# Implementation Notes — #392

## 修正範囲

中核 fix は `local-watcher/bin/issue-watcher.sh` の `dr_log()` 関数 1 ヶ所のみ
（L9666-9674 → L9666-9686 にコメントブロック拡張込みで変更）:

- **`dr_log()` (L9680)**: `echo "[$(date '+%F %T')] dr: $*"` → `echo "[$(date '+%F %T')] dr: $*" >&2`
  - これにより `dr_resolve_one` の OPEN + staged-for-release 解決パス
    （L9960 `dr_log "issue=#${dep_num} verdict=resolved reason=staged-for-release base=${BASE_BRANCH:-main}"`）
    の直後にある `echo "resolved"` が、呼び出し側 `verdict=$(dr_resolve_one ...)`
    （L10417 / `dr_unblock_resolve_one_issue` 内）に **戻り値のみ** を渡せる
    ようになる。
  - `dr_warn` (L9669) は本修正前から `>&2`、`dr_error` (L9672) も本修正前から `>&2`
    （要件 Req 4.3 / NFR 3.2 既存挙動維持）。
- 関数本体に至る理由・後方互換性・cron.log 集約位置を コメントブロックで説明
  （L9666-9678 のコメント追加 14 行）。

その他のコード変更なし（`dr_resolve_one` / `dr_unblock_resolve_one_issue` /
`dr_unblock_sweep` 等の本体ロジックは無変更）。

## 横展開チェック結果

要件 Req 5 / Req 6 の棚卸し:

**Req 5（dr 系 stdout 戻り値関数の棚卸し）**:

- `dr_resolve_one` (L9890): 5 終端パス（OPEN+staged / OPEN+ラベル無し /
  CLOSED+merged≥1 / CLOSED+merged=0 / api error 5 種）すべて `echo` で
  verdict 1 行を返す。本修正前は `dr_log` の stdout 汚染で同一実行パスに
  ログ行混入していたが、本修正で stdout が verdict 文字列のみに純化された。
- `dr_extract_deps` (L9695): 純粋関数。`dr_log` / `dr_warn` を呼ばない（確認済）。
- `dr_format_unresolved_comment` (L9751): 純粋関数。`dr_log` / `dr_warn` を呼ばず、
  内部で呼ぶ `dr_unblock_gate_enabled` も log を出さない（gate 判定のみ）。
- `dr_gh_graphql_closed_by` (L9809): GraphQL レスポンス JSON を stdout に返す。
  `dr_log` / `dr_warn` を呼ばない（確認済）。

→ Req 5.1〜5.4 すべて満たす。

**Req 6（他モジュール `*_log` の同型バグ横展開チェック）**: `*_log` 横展開チェック: **同型バグ無し**。

確認したモジュール集合（全 14 ロガー prefix）:

- `qa_log` / `mq_log` / `ar_log` / `pp_log` / `pi_log` / `drr_log` / `pr_log` /
  `sec_log` / `fr_log` / `sr_log`（`modules/core_utils.sh`）
- `sh_log`（`modules/scaffolding-health.sh`）
- `cm_log`（`modules/context-map.sh`）
- `sav_log`（`modules/stage-a-verify.sh`）
- `gh_log`（`modules/guard-hook.sh`）
- `am_log` / `amd_log` / `el_log` / `mqr_log` / `nda_log` / `po_log` / `sn_log`
  （個別モジュール）

すべて `dr_log` と同じく **stdout に echo する設計**（`*_warn` / `*_error` のみ `>&2`）。
ただし、`var=$(func ...)` パターンで stdout を機械可読戻り値として捕捉する
呼び出し箇所を網羅的に grep した結果（`grep -E '=\$\((dr_|qa_|mq_|...)'`）、
当該関数本体で `*_log`（stderr リダイレクトなし）を呼ぶ箇所は dr_resolve_one
以外には **存在しなかった**。

具体的に確認した「var=$()` パターンで呼ばれる関数」の本体内 `*_log` 呼び出し検索結果:

- `pr_detect_iteration_keyword` (pr-reviewer.sh L585): `pr_log ... >&2` で
  **明示的に stderr リダイレクト済み**（同型バグ防止対策が既に施されている）。
- `pr_build_prompt_file` (pr-reviewer.sh L395): コメントで「stdout に結果を返す
  契約のため pr_log は使わず pr_warn のみ使用」と明示。`pr_log` を呼ばない設計。
- その他の `drr_already_processed` / `drr_find_merged_design_pr` /
  `cm_render_prompt_section` / `po_parse_triage_edit_paths` /
  `fr_state_path` / `fr_load_state` / `fr_collect_*` / `fr_fetch_*` /
  `pi_read_last_run` / `pi_collect_*` / `pi_classify_*` / `pi_select_*` /
  `pi_resolve_max_rounds` / `pi_read_no_progress_streak` /
  `pi_build_iteration_prompt` / `pi_fetch_candidate_prs` / `pr_build_marker` /
  `cm_resolve_*`: 関数本体内で `*_log`（stderr リダイレクトなし）を呼んで
  いない（grep `_log\b` excluding `>&2` で 0 件）。

→ Req 6.1 / 6.3 充足。Req 6.4（Out of Scope）に従い他モジュールの `*_log`
出力先一括書き換えは **本 PR では行わない**。同型バグが見つかれば別 Issue 切り出し
する方針だが、今回は 0 件だったため別 Issue 不要。

## 追加テスト / 既存テスト改修

**追加テスト**: `local-watcher/test/dr_resolve_one_stdout_test.sh`（新規 509 行）

- `extract_function` イディオムで `dr_log` / `dr_warn` / `dr_error` /
  `dr_resolve_one` の **実体** を抽出して読み込み、`dr_gh_graphql_closed_by`
  のみを stub 化（GraphQL レスポンスを fixture 注入）。
- 全 9 ケースで 22 件の assert を実行:
  - Case 1: OPEN + staged-for-release + BASE_BRANCH=develop → stdout 厳密 `resolved`、
    `dr_log` 行が stderr に出ること / stdout に紛れ込まないこと（本 Issue 根因の直接検証）
  - Case 2: OPEN + ラベル無し → `open`
  - Case 2b: OPEN + BASE_BRANCH=main → `open`（既存挙動維持 / Req 3.2）
  - Case 3: CLOSED + merged≥1 → `resolved`
  - Case 4: CLOSED + merged=0 → `closed unmerged`（CLOSED node 1 件 / 空配列 2 fixture）
  - Case 5: GraphQL errors 検知 → `api error`
  - Case 6: 不正 JSON / state=null → `api error`
  - Case 7: gh rc!=0 → `api error`、dr_warn が stderr 出力 + stdout 汚染ゼロ
  - Case 8: `dr_log` / `dr_warn` / `dr_error` 単体の stdout 汚染ゼロ + フォーマット維持
  - Case 9: REPO env 不正 → `api error`

**Red→Green 確認**: `dr_log` の `>&2` を一時 revert すると 22 件中 6 件 FAIL、
本修正復元で 22 件全て PASS。本テストが本 Issue (#392) の根因を正しく検知することを確認。

**既存テストの改修**: なし。既存 `dr_unblock_sweep_test.sh` の `dr_log` / `dr_warn`
stub（L225-227）は本修正後も実害を引き起こさない構成（テスト隔離の都合上 stub する
こと自体は正当 / Req 7.5）。新規 stdout 純度テストの存在によって実 stdout 汚染を
検知できる体制になった。

## 検証ログ要約

| 検証項目 | コマンド | 結果 |
|---------|---------|------|
| 構文 | `bash -n local-watcher/bin/issue-watcher.sh` | OK |
| 構文 | `bash -n local-watcher/test/dr_resolve_one_stdout_test.sh` | OK |
| 静的解析 | `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh` | クリーン（rc=0、baseline 維持） |
| 静的解析 | `shellcheck local-watcher/test/dr_resolve_one_stdout_test.sh` | クリーン |
| 新規テスト | `bash local-watcher/test/dr_resolve_one_stdout_test.sh` | 22 PASS / 0 FAIL |
| 既存回帰 | `bash local-watcher/test/dr_unblock_sweep_test.sh` | 56 PASS / 0 FAIL |
| 既存回帰 | `bash local-watcher/test/dc_cycle_sweep_test.sh` | 74 PASS / 0 FAIL |
| 二重管理 | `diff -r .claude/agents repo-template/.claude/agents` | 空（同期維持） |
| 二重管理 | `diff -r .claude/rules repo-template/.claude/rules` | 空（同期維持） |

## README 反映の判断

本修正は **ユーザー可視仕様の変更ではない**（`dr_log` の挙動はメンテナ向け内部実装
詳細であり、cron 経由の集約位置は不変。grep 集計 `grep ' dr:'` も従来どおり機能する）。
要件 Req 8.2 で「必要時のみ追記」と規定されており、本修正は外部観測挙動を変えないため
README 反映は不要と判断。consumer repo にとっては「2-branch 運用で
DEP_AUTO_UNBLOCK が正しく動くようになった」というバグ修正の透過的反映であり、
README の挙動説明文を書き換える必要はない。

## AC Traceability

requirements.md の各 numeric ID に対する担保テスト:

| AC ID | 内容 | 担保 |
|-------|------|------|
| 1.1 | `dr_log` 出力先 stderr / stdout 1 文字も書かない | `dr_resolve_one_stdout_test.sh` Case 8 (dr_log 単体) + Case 1 (実経路) |
| 1.2 | `dr_warn` 出力先 stderr / stdout 1 文字も書かない | Case 8 (dr_warn 単体) + Case 7 (rc!=0 実経路) |
| 1.3 | OPEN + staged-for-release → stdout 厳密 `resolved` | Case 1 |
| 1.4 | OPEN + staged-for-release 無し → stdout 厳密 `open` | Case 2 |
| 1.5 | CLOSED + merged≥1 → stdout 厳密 `resolved` | Case 3 |
| 1.6 | CLOSED + merged=0 → stdout 厳密 `closed unmerged` | Case 4 (CLOSED node 1 件 / 空配列) |
| 1.7 | api error 経路 → stdout 厳密 `api error` | Case 5 (GraphQL errors) + Case 6 (不正 JSON / state=null) + Case 7 (gh rc!=0) + Case 9 (REPO 不正) |
| 1.8 | verdict=$(...) 捕捉が 4 値集合と完全一致 | Case 1 (case 4 値マッチ assert) |
| 2.1 | 2-branch DEP_AUTO_UNBLOCK 機能復旧 | Case 1 で OPEN + staged-for-release が `resolved` 1 行を返すことを実証 → 既存 `dr_unblock_sweep_test.sh` AT-a シナリオが本修正後も成立することで間接担保 |
| 2.2 | 構造化ログ `verdict=unblock_cleared` 維持 / `未知の verdict` 残らない | `dr_unblock_sweep_test.sh` 56 件 PASS（既存テストの構造化ログ assert は破壊されていない） |
| 2.3 | `blocked` 除去後の通常 pickup 合流 | Out of Scope（既存 #346 の動線。本修正で変更なし） |
| 3.1 | gate `=true` 以外で sweep 本体に到達しない | `dr_unblock_sweep_test.sh` AT-c で既に担保（本修正で破壊されていないことを 56 件 PASS で確認） |
| 3.2 | BASE_BRANCH=main で挙動一致 | Case 2b |
| 3.3 | CLOSED 経路 / api error 経路の挙動一致 | Case 3 / 4 / 5 / 6 / 7 |
| 3.4 | 既存 env var / ラベル / exit code / cron 文字列を変更しない | コード変更が `dr_log` 内 echo の `>&2` 追加のみで完了（env var / ラベル / exit code に触れていない） |
| 3.5 | `dr_unblock_sweep` 内のクエリ / FIFO / cycle 連携を変更しない | コード変更箇所 1 ヶ所のみ（`dr_unblock_sweep` 本体無変更） |
| 4.1 | cron.log で従来同じ 1 行フォーマットで観測 | Case 8 で `dr_log` の stderr フォーマット `[YYYY-MM-DD HH:MM:SS] dr: <message>` 維持を assert |
| 4.2 | メッセージ語彙・キー・prefix `dr:` 維持 | Case 1 で `dr: issue=#117 verdict=resolved reason=staged-for-release base=develop` フォーマット維持を assert |
| 4.3 | `dr_error` 出力先 stderr 維持 | Case 8 (dr_error 単体) |
| 5.1 | `dr_resolve_one` 5 終端パスで stdout verdict 1 行のみ | Case 1〜7 + Case 9（5 経路 + 2 buf）全て厳密一致 assert |
| 5.2 | `dr_extract_deps` stdout が Issue 番号集合のみ | コード review で確認（dr_log/dr_warn 呼び出しなし）。既存 `dr_unblock_sweep_test.sh` の依存抽出シナリオで間接担保 |
| 5.3 | `dr_format_unresolved_comment` stdout がコメント本文のみ | コード review で確認（dr_log/dr_warn 呼び出しなし）。既存 `dr_unblock_sweep_test.sh` AT-h で文面分岐を担保 |
| 5.4 | `dr_gh_graphql_closed_by` stdout が GraphQL JSON のみ | コード review で確認（dr_log/dr_warn 呼び出しなし）。Case 1〜9 で fixture 注入を経て dr_resolve_one が正常 verdict を返すことで間接担保 |
| 6.1〜6.4 | 他モジュール `*_log` 横展開チェック | 上記「横展開チェック結果」節で 0 件、Req 6.4 に従い本 PR では一括書き換えなし |
| 7.1〜7.5 | 回帰防止テスト | `dr_resolve_one_stdout_test.sh` 22 件全て、特に Red→Green を実証済み |
| 8.1〜8.3 | root↔repo-template 同期 / README 反映 | `.claude` 変更なし / `diff -r` 空確認済み、README 反映不要の判断を本ノートに記載 |
| NFR 1.1〜1.2 | `bash -n` / `shellcheck` 警告ゼロ | 検証ログ要約参照 |
| NFR 2.1〜2.3 | 後方互換性 | Case 2b（main 維持）/ 3.3 担保 / 戻り値語彙 4 値変更なし |
| NFR 3.1〜3.2 | 可観測性 | Case 8 でフォーマット維持 / Case 1 で staged-for-release 解決時の語彙・キー順序維持 |
| NFR 4.1 | 未信頼入力リダイレクト破壊なし | 変更は `>&2` 追加のみで未信頼値の取り扱いに影響なし（クォート維持） |

## 確認事項

なし。本 Issue の requirements.md / 対象コード / 横展開チェック / 既存テストとの整合は
すべてクリア。Out of Scope（他モジュールの `*_log` 一括書き換え等）も Req 6.4 の方針に
従って本 PR では扱わない。

STATUS: complete
