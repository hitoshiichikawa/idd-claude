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
| 5.3 | 説明コメント投稿 | `po_apply_awaiting_slot` 内の sticky comment 作成 / 更新 |
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
| 8.1 | overlap 検出ログ | `po_log "overlap detected candidate=#${candidate} paths=..."` |
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
| 12.1 | candidate あたり 1 read + 1 比較 | `po_load_edit_paths` は `gh issue view --json comments` を 1 回のみ呼び、has_awaiting 判定は dispatcher candidate query から取得済の `labels_json` を再利用 |
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

## 派生タスクとして切り出し候補

- Triage prompt 側で「過剰列挙より厳選を優先」の指示が遵守されない場合、Issue ごとに `edit_paths`
  が 50 件以上返るケースが観測されたら、watcher 側で `edit_paths` 件数上限（例: 20 件）を強制
  する fail-safe を追加する別 Issue を起票する
- `po_collect_inflight_issues` の N+1 が実運用で顕在化したら GraphQL bulk fetch 化を別 Issue で
  対応
- README の Phase E 節と「ラベル状態遷移まとめ」表の二重管理が将来煩雑になったら、ラベル定義
  を tab に集約するリファクタを別 Issue で検討
