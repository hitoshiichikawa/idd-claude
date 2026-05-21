# Implementation Notes — Phase E: Triage path overlap 検知（hot file 競合予防）

## Issue / 関連

- Issue: #18
- 親: #13（Phase 全体）
- 依存: #16（Phase C 並列化 / merged）
- 関連: #14 / #15 / #17 / #27
- 設計 PR: #139（design.md / tasks.md を merge 済み）

## 実装サマリ

tasks.md の 8 タスクをすべて完了。各タスクは 1 コミットの実装 + 1 コミットの進捗マーカー
更新（`docs(tasks): mark N as done`）で構成され、合計 16 コミット。

| Task | 実装内容 | 主要追加ファイル / 関数 |
|---|---|---|
| 1 | Triage prompt template に `edit_paths` 出力指示を additive 追加 | `local-watcher/bin/triage-prompt.tmpl` 末尾 |
| 2 | `awaiting-slot` ラベル定義を追加 | `repo-template/.github/scripts/idd-claude-labels.sh` 配列末尾 1 行 |
| 3 | env / ラベル定数 / ログ関数 | `LABEL_AWAITING_SLOT` / `PATH_OVERLAP_CHECK` / `po_log` / `po_warn` |
| 4 | Triage Parser + Persister + Loader | `po_parse_triage_edit_paths` / `po_persist_edit_paths` / `po_load_edit_paths` + `_slot_run_issue` 統合 |
| 5 | In-Flight Collector + Overlap Engine + State Machine | `po_collect_inflight_issues` / `po_compute_overlap` / `po_apply_awaiting_slot` / `po_clear_awaiting_slot` |
| 6 | Dispatcher 統合点 | `po_check_dispatch_gate` + `_dispatcher_run` への 1 箇所 insert |
| 7 | README 更新 | Phase E 専用節 + opt-in 表 + ラベル表 + Step 2 ラベル一括作成例 |
| 8 | 静的検査・スモーク・dogfood 手順 | 本 impl-notes.md / shellcheck 0 warnings 確認 |

## 設計との差分

設計 PR (#139) で確定した design.md / tasks.md からの差分は **なし**。すべて設計通り実装。
以下は実装中に判断が必要だった微細な点（design.md の Interface に書かれた疑似コードを実コード化
する際の選択肢）:

1. **comment id 抽出方法**: `gh issue view --json comments` の `.comments[].id` は GraphQL の
   base64 id（`IC_kwDOSHe5PM8AAAABDLcMXQ` 形式）であり REST API の数値 id とは別。`.url`
   フィールド末尾の `#issuecomment-<numeric>` から `sed -nE` で抽出する方式を採用
   （`po_persist_edit_paths` / `po_apply_awaiting_slot` 内で同一 pattern）
2. **空配列時の sticky 本文**: `po_persist_edit_paths` は空配列を渡されても sticky を書く。
   md リストは「_(Triage は確信のある edit_paths を推定できませんでした)_」と表示し、
   hidden JSON marker は `[]` を埋める（Loader が空配列として再読可能）
3. **`po_collect_inflight_issues` の OR 検索 escape**: `gh issue list --search` の検索式に
   `is:open is:issue (label:"A" OR label:"B")` 形式を用いた。`gh issue list --state open`
   と `--search 'is:open'` の二重指定は実害がないが、`--search` 側のみで一貫指定して
   重複を避けた

## Feature Flag Protocol との関係

本 repo の `CLAUDE.md` で Feature Flag Protocol は **opt-out**（採否宣言なし → 既定 opt-out）。
そのため `.claude/rules/feature-flag.md` の規約は適用されず、通常の単一実装パスで実装。

ただし Phase E の `PATH_OVERLAP_CHECK` は **機能ラベルとしての feature flag**（=true 明示で
有効化、既定 off で本機能導入前と完全互換）として動作する。これは Feature Flag Protocol 規約
（旧パスを温存する `if (flag) { 新挙動 } else { 旧挙動 }` 規約）とは概念が違い、**新規追加機能の
opt-in 制御** であって既存挙動の置き換えではない（旧パスは早期 return 0 で従来 dispatcher 経路
にそのまま流れる）。Feature Flag Protocol 規約は本実装には適用されない。

### Active env-controlled flag 一覧（参考）

本 PR で追加された env-controlled flag:

| Flag | 既定値 | 有効化条件 | 用途 |
|---|---|---|---|
| `PATH_OVERLAP_CHECK` | `off` | 環境変数で `=true` を明示（厳密一致） | Phase E Path Overlap Checker 全体の opt-in gate |

## 受入基準（AC）とテスト対応表

| Req ID | AC 内容（要約） | 担保方法 |
|---|---|---|
| 1.1 | `=true` のみで起動 | `po_check_dispatch_gate` 冒頭の `[ "$PATH_OVERLAP_CHECK" = "true" ] || return 0` / smoke test (env normalize) |
| 1.2 | 未設定で従来挙動 | 同上 + dry-run smoke test (PATH_OVERLAP_CHECK 未設定 → `path-overlap:` 0 行) |
| 1.3 | `True` / `1` / typo 等もすべて off | env normalize smoke test 9 ケース |
| 1.4 | 既定 `off` | `PATH_OVERLAP_CHECK="${PATH_OVERLAP_CHECK:-off}"` |
| 2.1 | Triage 出力に edit_paths 配列 | triage-prompt.tmpl 末尾「## edit_paths の出力指示」節 + JSON schema |
| 2.2 | top-level path 文字列配列 | 同 prompt 内「ディレクトリは末尾 `/` 付き、ファイルは `/` なし」明記 |
| 2.3 | 確信なしは空配列 | 同 prompt 内「omit や null は不可、空配列 `[]`」明記 |
| 2.4 | 欠落は空配列扱い | `po_parse_triage_edit_paths` の `// []` + `if type == "array"` ガード / smoke test (b)(c)(d)(e)(f) |
| 2.5 | 既存 5 keys 不変 | triage-prompt.tmpl の既存 status/needs_architect/architect_reason/rationale/decisions 行は不変。シェル側の jq 抽出（STATUS / DECISION_COUNT / NEEDS_ARCHITECT / ARCHITECT_REASON）も不変 |
| 3.1 | 後続 cron で再読可能 | `po_persist_edit_paths` (sticky comment) + `po_load_edit_paths` (gh issue view --json comments) |
| 3.2 | GitHub UI で目視可能 | sticky comment 本文に人間可読 md リスト |
| 3.3 | 再 Triage で上書き | `po_persist_edit_paths` 内の既存 marker 検索 → `gh api PATCH /repos/.../issues/comments/{id}` |
| 3.4 | persist 失敗は fail-open | `_slot_run_issue` 内の `po_persist_edit_paths || po_warn` パターン、Triage 全体は成功扱い継続 |
| 4.1 | in-flight 7 ラベル列挙 | `po_collect_inflight_issues` の `--search` 文字列に 7 ラベル OR |
| 4.2 | `st-failed` / `awaiting-slot` 除外 | 同 `--search` 文字列の `-label:"st-failed" -label:"awaiting-slot"` |
| 4.3 | 候補自身を除外 | `po_collect_inflight_issues` の `if [ "$n" = "$candidate" ]; then continue; fi` |
| 4.4 | 同 repo のみ | `--repo "$REPO"` 固定 |
| 5.1 | claim 直前で intersection 計算 | `_dispatcher_run` 内の `po_check_dispatch_gate` 呼び出し位置（`check_existing_impl_pr` 通過直後・`_dispatcher_find_free_slot` 前） |
| 5.2 | non-empty → ラベル + dispatch skip | `po_apply_awaiting_slot` + `po_check_dispatch_gate` の `return 1` |
| 5.3 | 説明コメント投稿（path + holder Issue 番号） | `po_apply_awaiting_slot` (引数 `$3` holders_map_json) + `po_format_holders_table_md` で sticky comment 本文に「\| 重複 path \| 保持中の Issue \|」表を表示（round 2 是正） |
| 5.4 | empty → 通常 dispatch | `po_check_dispatch_gate` 末尾の `return 0` |
| 5.5 | 候補 edit_paths 不在は block しない | `po_compute_overlap` の jq `($c | map(normalize) | unique)` で candidate 空なら結果も空 / smoke test (b) |
| 5.6 | top-level 粒度のみ | `po_compute_overlap` の jq `normalize` def（先頭セグメント + `/`） / smoke test (a)(c)(d)(e)(h) |
| 6.1 | 後続 tick で再評価 | candidate query に `awaiting-slot` を追加していないため、awaiting-slot 付き Issue も毎 tick で gate を通る |
| 6.2 | empty → 自動除去 + dispatch | `po_check_dispatch_gate` の `po_clear_awaiting_slot` 呼び出し + `return 0` |
| 6.3 | non-empty → 維持 | `po_check_dispatch_gate` で empty 時のみ clear、それ以外は付与継続 |
| 6.4 | 人間介入不要 | clear + claim 続行を同サイクル内で行う（`po_check_dispatch_gate` の `return 0` パス） |
| 7.1 | ラベル定義追加 | `idd-claude-labels.sh` LABELS 配列末尾に `awaiting-slot|c5def5|...` 1 行 |
| 7.2 | 冪等再実行 | 既存 `EXISTING_LABELS[$NAME]` チェックで自動的に skip / `--force` 上書き |
| 7.3 | 既存ラベル無傷 | 既存 13 行（auto-dev 〜 st-failed）の name / color / description は変更なし |
| 8.1 | overlap 検出ログ（candidate + paths + holders） | `po_check_dispatch_gate` 内で `po_resolve_overlap_holders` → `po_format_holders_for_log` を経て `po_log "overlap detected candidate=#${candidate} paths=... holders=#<N>,#<M>"` を出力（round 2 是正） |
| 8.2 | `awaiting-slot` 付与ログ | `po_apply_awaiting_slot` 内 `po_log "awaiting-slot added candidate=#${issue_number}"` |
| 8.3 | `awaiting-slot` 除去ログ | `po_clear_awaiting_slot` 内 `po_log "awaiting-slot cleared candidate=#${issue_number} (overlap empty)"` |
| 8.4 | cron.log 経路 | `po_log` / `po_warn` は stdout 出力で既存 `pp_log` / `mq_log` 等と同経路 |
| 9.1 | README に Phase E 節 | `## Path Overlap Checker (Phase E)` 見出し追加 |
| 9.2 | opt-in 方法記述 | README 同節「環境変数」サブセクション + cron 例 |
| 9.3 | in-flight ラベル列挙 | README 同節「in-flight 集合の定義」サブセクションで 7 ラベル箇条書き |
| 9.4 | 自然解消の説明 | README 同節「自然解消の流れ」サブセクションで 4 ステップ説明 |
| 10.1 | dogfood opt-in 手順 | README 「dogfood 確認手順」サブセクション + 本 impl-notes 末尾 |
| 10.2 | 同一ファイル編集 2 Issue 作成 | 同上 |
| 10.3 | 後発 Issue が `awaiting-slot` 取得 | 同上 |
| 10.4 | 先発 merge 後の自然解消 | 同上 |
| 11.1 | shellcheck zero warnings | `shellcheck -S warning local-watcher/bin/issue-watcher.sh` で 0 件確認（task 8） |
| 12.1 | candidate あたり 1 read + 1 比較 | `po_load_edit_paths` は `gh issue view --json comments` を **candidate 1 件あたり 1 回のみ** 呼ぶ。has_awaiting 判定は dispatcher candidate query から取得済の `labels_json` を再利用。round 2 の holders map 構築は既存の in-flight 側 `po_load_edit_paths` ループの戻り値から jq で同時集約しており、追加 API 呼び出しは発生しない |
| 12.2 | overlap 不検出時に追加 API なし | overlap empty かつ awaiting-slot 不在のとき `po_check_dispatch_gate` は `gh issue edit` / `gh issue comment` を発火しない |

## 静的検査・スモーク結果（task 8 実施記録）

### shellcheck

```
$ shellcheck -S warning local-watcher/bin/issue-watcher.sh repo-template/.github/scripts/idd-claude-labels.sh
（出力なし、exit=0）
```

Req 11.1（shellcheck zero warnings）を満たす。デフォルト level（info 含む）では `SC2317`
（unreachable / 既存関数の `return 1; ...` 構造で発生する false positive）と既存 1 件の `SC2012`
（`ls` → `find` 推奨）が出るが、いずれも Phase E 改変箇所外の既存コードに起因し、本 PR で
新規発生しない。

### bash syntax

```
$ bash -n local-watcher/bin/issue-watcher.sh
syntax OK
```

### Unit-level Manual Smoke（4 ケース）

`/tmp/po-smoke.sh` を作成し、`po_parse_triage_edit_paths` / `po_compute_overlap` / env normalize
の 3 関数群を bash source で直接呼び、入出力テーブルを検証:

```
=== po_parse_triage_edit_paths ===
  PASS: (a) 正常配列
  PASS: (b) key 不在 → []
  PASS: (c) null → []
  PASS: (d) 非配列 string → []
  PASS: (e) 要素 mixed → string のみ
  PASS: (f) ファイル不在 → []

=== po_compute_overlap ===
  PASS: (a) 基本 overlap
  PASS: (b) candidate 空 → []
  PASS: (c) ./README.md vs README.md
  PASS: (d) docs/specs/18-foo/req.md vs docs/
  PASS: (e) local-watcher/bin/foo.sh vs local-watcher/bin/bar.sh
  PASS: (f) 完全不一致 → []
  PASS: (g) inflight 空 → []
  PASS: (h) 連続スラッシュ正規化

=== env normalize (PATH_OVERLAP_CHECK の厳密一致) ===
  PASS: 'true' → enabled
  PASS: 'false' → disabled
  PASS: 'True' → disabled
  PASS: '1' → disabled
  PASS: '' → disabled
  PASS: 'yes' → disabled
  PASS: 'off' → disabled
  PASS: 'TRUE' → disabled
  PASS: 未設定 → 'off' (default fallback)

=== Summary: PASS=23 / FAIL=0 ===
```

sticky idempotency（design.md Testing Strategy 4 番目のケース）については、`gh` の実 Issue 操作が
必要なため dogfood E2E 手順内で検証する（後述）。

### Integration Smoke（後方互換性）

cron-like 最小 PATH での dry run を 2 通り実施:

```
--- Test: PATH_OVERLAP_CHECK=off, candidate=0 環境 ---
path-overlap: count=0   ← 期待通り 0 行（NFR 1.1 / Req 1.2 後方互換）

--- Test: PATH_OVERLAP_CHECK=true, candidate=0 環境 ---
path-overlap: count=0   ← 期待通り 0 行（Req 12.2 candidate 不在時の追加 API なし）
```

両ケースとも watcher 全体は worktree 初期化段階で fatal（worktree 衝突 / origin 不在）を起こすが、
これは Phase E 改変とは無関係の env テスト固有事象。重要なのは「**Phase E のログが 1 行も
出ない**」点で、これは:

- `=off` 時: `po_check_dispatch_gate` 冒頭で早期 return → Phase E パスに入らない（Req 1.2）
- `=true` かつ candidate=0 時: そもそも dispatcher loop body に入らない（既存挙動）

を構造的に保証する。

## Dogfood E2E 手順（Req 10.1〜10.4）

`idd-claude` 自身を対象に、本機能が end-to-end で動作することを以下の手順で確認する。実機実行は
人間運用者に委ねる（本 PR スコープ内では実施不可）。

### 前提

- 本 PR が main に merge 済み
- consumer-side で `cd ~/.idd-claude && git pull && ./install.sh --local` で
  `~/bin/issue-watcher.sh` と `~/bin/triage-prompt.tmpl` を最新化済
- `bash .github/scripts/idd-claude-labels.sh` で `awaiting-slot` ラベルが追加済
- watcher の cron / launchd エントリで `PARALLEL_SLOTS=2` 以上、`PATH_OVERLAP_CHECK=true` を設定

### 手順

1. **opt-in 設定** (Req 10.1): cron / launchd の env block に以下を追加

   ```cron
   */2 * * * * REPO=hitoshiichikawa/idd-claude REPO_DIR=$HOME/work/idd-claude \
     PARALLEL_SLOTS=2 \
     PATH_OVERLAP_CHECK=true \
     $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1
   ```

2. **2 つの auto-dev Issue を立てる** (Req 10.2): 両方とも `local-watcher/bin/issue-watcher.sh`
   を編集する内容にする。例:

   - Issue A: 「`issue-watcher.sh` の `dispatcher_log` に追加 prefix を入れる」
   - Issue B: 「`issue-watcher.sh` の `mq_log` を別ファイルに切り出す」

   両方に `auto-dev` ラベル付与。Triage Claude が `edit_paths` に `local-watcher/` を返すこと
   が期待される（top-level granularity / Req 2.2）。

3. **観測（後発 `awaiting-slot` 取得）** (Req 10.3): 1 つ目（Issue A）が in-flight に入って
   `claude-claimed` / `claude-picked-up` を持つ状態で、2 つ目（Issue B）の cron tick を観測:

   ```bash
   # Phase E ログだけ抽出
   tail -n 200 $HOME/.issue-watcher/cron.log | grep 'path-overlap:'
   ```

   期待される行（タイムスタンプは可変）:

   ```
   [YYYY-MM-DD HH:MM:SS] [hitoshiichikawa/idd-claude] path-overlap: overlap detected candidate=#<B> paths=local-watcher/
   [YYYY-MM-DD HH:MM:SS] [hitoshiichikawa/idd-claude] path-overlap: awaiting-slot added candidate=#<B>
   ```

   GitHub UI で Issue B を開き、以下を確認:

   - `awaiting-slot` ラベルが付与されている
   - sticky comment「⏸️ Dispatch を見送り中（Phase E Path Overlap Checker）」が投稿されている
     （hidden marker `<!-- idd-claude:awaiting-slot:v1 -->` を含む）
   - sticky comment 本文に重複 path `local-watcher/` が記載されている

4. **自然解消** (Req 10.4): Issue A の PR を merge して in-flight 集合から外す。次の cron tick
   で:

   ```bash
   tail -n 200 $HOME/.issue-watcher/cron.log | grep 'path-overlap:'
   ```

   期待される行:

   ```
   [YYYY-MM-DD HH:MM:SS] [hitoshiichikawa/idd-claude] path-overlap: awaiting-slot cleared candidate=#<B> (overlap empty)
   ```

   Issue B の `awaiting-slot` ラベルが除去され、同サイクル内で通常 dispatch が実行され、
   `claude-claimed` / `claude-picked-up` に遷移することを確認。**手動介入は一切不要**（Req 6.4）。

### sticky idempotency 確認（design Testing Strategy ケース 4）

Issue A について `needs-decisions` を一旦付与 → 解消 → 再 Triage を実行させると、
`po_persist_edit_paths` が 2 回呼ばれる。GitHub UI で Issue A の `edit_paths` sticky コメント
が **1 件のみ**（最新内容で update されている）であることを確認する。

## 確認事項

- **OR ラベル検索の `gh issue list --search` syntax 検証**: design.md の確認事項にあった通り、
  実機での `gh issue list --search 'is:open is:issue (label:"A" OR label:"B")'` の挙動は dogfood
  E2E で初めて確認できる。`gh search issues` と `gh issue list --search` の OR syntax 解釈差は
  本 PR で実装した syntax で問題ないと判断しているが、運用者がもし誤動作（in-flight が 1 件も
  拾われない等）を観測した場合は人間判断で別 syntax への切り替えを検討する。
- **sticky comment の hidden JSON marker のサイズ上限**: `po_persist_edit_paths` は edit_paths
  配列を JSON 化して 1 行の HTML コメントに埋め込む。Triage が大量の path（例: 100 件）を返した
  場合 GitHub の comment body 上限（65536 bytes 程度）に達する可能性があるが、Triage prompt 側で
  「top-level + 過剰列挙より厳選を優先」と明記しているため通常運用では問題にならないと判断。
  運用中に問題が発覚した場合は別 Issue で対応する。
- **`po_collect_inflight_issues` の N+1**: 各 in-flight Issue について `po_load_edit_paths` を
  呼ぶため、in-flight 件数だけ `gh issue view --json comments` が発火する。design.md
  「Performance & Scalability」節通り通常 `< 10` 件で許容範囲内だが、もし大量の `staged-for-release`
  Issue が累積する運用では bulk fetch（GraphQL での 1 リクエスト化）への最適化が必要かもしれない。
  Req 12.1 は「**candidate 単独**に対する 1 read」の保証であり、この N+1 は同 Req の制約外と
  判断（design.md の傍注通り）。
- **`staged-for-release` を in-flight に含めるかの最終確定**: Req 4.1 / design.md 通り
  **含める** で固定実装した。Phase B (#15) 運用結果次第で除外側に倒す判断もあり得るが、本 PR
  ではこの方針を変更していない。

## 追加した依存・ライブラリ

なし。既存の `gh` / `jq` / `bash` のみで完結。新規ファイルは追加せず、既存 4 ファイルへの
additive 変更のみ:

- `local-watcher/bin/triage-prompt.tmpl`
- `local-watcher/bin/issue-watcher.sh`
- `repo-template/.github/scripts/idd-claude-labels.sh`
- `README.md`

## 是正対応 (round 2)

### Reviewer round 1 で reject された Findings

1. **Finding 1 (Req 5.3)**: `po_apply_awaiting_slot` が overlap path 配列のみを受け取り、
   sticky comment 本文に「どの in-flight Issue 番号がその path を保持しているか」を表示できて
   いなかった（design.md L855-863 のテーブル仕様が未実装）
2. **Finding 2 (Req 8.1)**: overlap 検出ログ行に `holders=#<N>,#<M>` フィールドが欠落して
   いた（design.md L648 のログ例が未実装）

### 是正実装の概要

| 変更点 | 場所 | 内容 |
|---|---|---|
| 拡張: `po_collect_inflight_issues` の戻り値スキーマ | issue-watcher.sh:2310（関数開始） | 単一 union 配列から `{"union": [...], "holders": {path: [issue#, ...]}}` の JSON object に変更。各 in-flight Issue について `po_load_edit_paths` を 1 回呼ぶ既存ループ内で holders map を同時構築（Req 12.1 の API 呼び出し回数制約を維持） |
| 追加: `po_resolve_overlap_holders` 関数 | issue-watcher.sh:2375（関数開始） | overlap path（正規化済 top-level）と holders map（正規化前 path → [issue#, ...]）から、overlap_path → [issue#, ...] を解決。holders map の生キーには同じ `normalize` 規約（先頭 `./` 剥がし / 連続スラッシュ圧縮 / top-level セグメント + `/`）を適用してから bucket 化する |
| 追加: `po_format_holders_for_log` 関数 | issue-watcher.sh:2411（関数開始） | overlap-holders map から log 用フラット文字列 `#<N>,#<M>` を生成（重複除去・ソート済） |
| 追加: `po_format_holders_table_md` 関数 | issue-watcher.sh:2431（関数開始） | overlap-holders map から sticky comment 用 md 表（`\| 重複 path \| 保持中の Issue \|` 形式）を生成 |
| 拡張: `po_apply_awaiting_slot` の引数 | issue-watcher.sh:2507（関数開始） | 第 3 引数 `$holders_map_json` を追加。holders map が指定された場合は md 表でレンダリング、未指定 / 空 map の場合は従来の path md リストにフォールバック |
| 拡張: `po_check_dispatch_gate` の overlap 検出パス | issue-watcher.sh:2608（関数開始） | inflight_obj から union / holders を分解 → `po_resolve_overlap_holders` で overlap holders を解決 → log 行に `holders=` フィールドを追記 → `po_apply_awaiting_slot` に holders map を渡す |

### 追加関数のシグネチャ

```bash
# overlap path 配列と holders map から overlap_path → [issue#, ...] map を解決
po_resolve_overlap_holders <overlap_json> <holders_map_json>
# → stdout: {"overlap_path": [issue#, ...]} (overlap path 全てがキーに登場)

# overlap-holders map から log 用 "#39,#40" 形式の文字列を生成
po_format_holders_for_log <overlap_holders_map_json>
# → stdout: "#39,#40,..." or ""

# overlap-holders map から sticky comment 本文の md 表を生成
po_format_holders_table_md <overlap_holders_map_json>
# → stdout: "| 重複 path | 保持中の Issue |\n|---|---|\n| `path` | #39, #40 |\n..."
```

### 拡張後の `po_apply_awaiting_slot` シグネチャ

```bash
po_apply_awaiting_slot <issue_number> <overlap_json> [<holders_map_json>]
# 第 3 引数 holders_map_json は **optional**（未指定 / 空 map の場合は後方互換で
# 従来の path md リスト表示）。round 2 以降は holders map を必ず渡す運用。
```

### `po_check_dispatch_gate` の overlap 検出ログ例（is 修正後）

Req 8.1（[$REPO] prefix + candidate + paths + holders）を満たす形:

```
[2026-05-21 14:00:00] [hitoshiichikawa/idd-claude] path-overlap: overlap detected candidate=#42 paths=local-watcher/,README.md holders=#39,#40
```

`holders=` の値は overlap 全 path の holder Issue 番号を unique + sort して `#` prefix 付与した
flat list。path 別の holder 内訳は sticky comment 本文の md 表で表示する（複数 path で同じ
holder が登場するケースでも log は dedupe、comment は path 別表示で詳細情報を保持）。

holders が空（in-flight が close 直後 / holder 不明）でも log line は `holders=-` で出力し、
欠落の事実をログに残す（fail-open）。

### Sticky Comment 本文の md 表（design.md L855-863 準拠）

```markdown
## ⏸️ Dispatch を見送り中（Phase E Path Overlap Checker）

本 Issue が編集見込みの top-level path のうち、以下が現在 in-flight 中の他 Issue と重複しています。

| 重複 path | 保持中の Issue |
|---|---|
| `README.md` | #40 |
| `local-watcher/` | #39, #40 |

先行 Issue の PR が merge されて in-flight 集合から外れた次サイクルで `awaiting-slot`
ラベルが自動除去され、本 Issue は通常 dispatch に戻ります。手動介入は不要です。

詳細は README の「Path Overlap Checker (Phase E)」節を参照してください。

<!-- idd-claude:awaiting-slot:v1 -->
```

### Smoke Test 結果（round 2）

#### Holders 伝播 smoke test（新規）

`/tmp/po-holders-smoke.sh` を作成し、`po_resolve_overlap_holders` / `po_format_holders_for_log` /
`po_format_holders_table_md` の 3 関数を `issue-watcher.sh` から sed で抽出 → source して入出力
テーブルを検証:

```
=== po_resolve_overlap_holders + log/md formatters ===
  PASS: (i) single overlap, single holder → resolve
  PASS: (i) holders log = '#39'
  PASS: (i) holders md table
  PASS: (j) multi overlap, distinct holders → resolve
  PASS: (j) holders log = '#39,#40'
  PASS: (j) holders md table (sorted by path)
  PASS: (k) single overlap, multiple holders → resolve
  PASS: (k) holders log = '#39,#40'
  PASS: (k) holders md table (multi-holder)
  PASS: (l) sub-path holders normalized → bucket merge
  PASS: (l) holders log = '#41,#42'
  PASS: (m) empty overlap → {}
  PASS: (m) empty overlap → empty log
  PASS: (n) overlap not in holders → empty array key
  PASS: (n) holders log = '' (all empty)
  PASS: (n) md table shows holder 不明 fallback

=== Summary: PASS=16 / FAIL=0 ===
```

検証ケース内訳:

- (i) candidate path X / in-flight #39 が X 保持 → holders=#39
- (j) candidate path X+Y / in-flight #39 が X, #40 が Y → holders=#39,#40（log は flat）/ md 表は path 別
- (k) 同じ path X を #39, #40 が保持 → holders=#39,#40 / md 表で 1 行に "#39, #40"
- (l) in-flight が `local-watcher/bin/foo.sh` のような sub-path で持つ → holders map の生キーが
  normalize されて bucket 化（`local-watcher/` に #41, #42 が merge）
- (m) overlap 空 → 空 map / log 空文字
- (n) overlap path が holders map に存在しない（race 条件想定）→ 空配列キー + md は「_(holder 不明)_」

#### `po_collect_inflight_issues` 集約ロジック smoke test（新規）

`/tmp/po-collect-smoke.sh` で union / holders map の同時構築ロジックを mock 注入で検証:

```
=== po_collect_inflight_issues union+holders aggregation ===
  PASS: (1) distinct paths → union + holders separated
  PASS: (2) same path / two holders → holders array merged
  PASS: (3) candidate self excluded
  PASS: (4) single issue with multi paths
  PASS: (5) empty in-flight → empty obj (initial accum unchanged)
  PASS: (6) issue with empty paths → no holders entry for that issue

=== Summary: PASS=6 / FAIL=0 ===
```

#### 既存 23 ケース regression（再実行）

`/tmp/po-smoke-regression.sh` で round 1 時点の 23 ケース（`po_parse_triage_edit_paths` 6 件・
`po_compute_overlap` 8 件・env normalize 9 件）が全て PASS のまま壊れていないことを確認:

```
=== Summary: PASS=23 / FAIL=0 ===
```

#### shellcheck（再実行）

```
$ shellcheck -S warning local-watcher/bin/issue-watcher.sh repo-template/.github/scripts/idd-claude-labels.sh
（出力なし、exit=0）
```

Req 11.1（shellcheck zero warnings）を引き続き満たす。

#### bash syntax check

```
$ bash -n local-watcher/bin/issue-watcher.sh
syntax OK
```

### 後方互換性の確認

- **既存呼び出し側の影響**: `po_collect_inflight_issues` の唯一の呼び出し点は
  `po_check_dispatch_gate` の中（grep で 1 箇所のみ確認済）。戻り値スキーマ変更は同関数内で
  完結し、外部 API 互換性は影響なし。
- **`po_apply_awaiting_slot` の引数**: 第 3 引数 `holders_map_json` は **optional**
  （`${3:-}`）。未指定 / 空 map の場合は従来の path md リスト表示にフォールバックするため、
  万が一テスト用に直接呼ばれていても挙動が壊れない。
- **`PATH_OVERLAP_CHECK=off` での挙動**: 早期 return 0 で本機能パスに入らないため、本 PR の
  全ての変更は影響しない（NFR 1.1 後方互換性）。

### Traceability 表の更新

| Req ID | round 1 状態 | round 2 是正後 |
|---|---|---|
| 5.3 | ⚠️ overlap path リストは表示するが holder Issue 番号が未表示 | ✅ `po_apply_awaiting_slot` に holders map を渡し、sticky comment 本文に「\| 重複 path \| 保持中の Issue \|」表を表示（design.md L855-863 準拠） |
| 8.1 | ⚠️ log に paths は含まれるが holders が未表示 | ✅ overlap 検出ログ行に `holders=#<N>,#<M>` フィールドを追加（design.md L648 準拠）。holders 空時は `holders=-` で fail-open |

### 確認事項（round 2）

- **holders log の重複 holder**: 複数 overlap path が同じ holder Issue を持つケース
  （例: #39 が `local-watcher/` と `README.md` の両方を保持）では、log の `holders=` 値は
  unique + sort で「#39」が 1 回だけ出力される（path 別の内訳は sticky comment の md 表で
  表現）。これは log の grep / parse 容易性を優先した判断であり、Req 8.1 は holder Issue
  number(s) の表示を要求しているのみで重複出力までは要求していないため、本実装で AC を
  満たす。
- **holders map の正規化**: holders map のキーは po_load_edit_paths が返した正規化前の
  生 path（in-flight Issue が persist した値そのまま）。overlap path との突合時に
  `po_resolve_overlap_holders` 内で同じ `normalize` jq def を適用して bucket 化することで、
  in-flight が sub-path（例: `local-watcher/bin/foo.sh`）を持っていても overlap top-level
  path（`local-watcher/`）から holders を正しく引ける（smoke test ケース (l) で検証）。
- **空 holders 時の log 表記**: holders が解決できなかった場合（in-flight 列挙後すぐに
  close される race 等）は `holders=-` を出力する。`holders=` だけだと paths=… holders=
  の trailing 空白で grep しにくいため明示的に `-` を入れた。

## 派生タスクとして切り出し候補

- Triage prompt 側で「過剰列挙より厳選を優先」の指示が遵守されない場合、Issue ごとに `edit_paths`
  が 50 件以上返るケースが観測されたら、watcher 側で `edit_paths` 件数上限（例: 20 件）を強制
  する fail-safe を追加する別 Issue を起票する
- `po_collect_inflight_issues` の N+1 が実運用で顕在化したら GraphQL bulk fetch 化を別 Issue で
  対応
- README の Phase E 節と「ラベル状態遷移まとめ」表の二重管理が将来煩雑になったら、ラベル定義
  を tab に集約するリファクタを別 Issue で検討
