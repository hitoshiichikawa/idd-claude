# 実装ノート — #368 cycle 検出 → needs-decisions エスカレーション（D-16）

## 概要

依存グラフの閉路を検出して `needs-decisions` を冪等付与する dep-cycle-detect モジュールを
新規追加。既存 #346 Dependency Auto-Unblock Sweep の前処理として同居起動し、閉路メンバーは
auto-unblock の `blocked` 解除対象から除外する。`DEP_AUTO_UNBLOCK_ENABLED=true` 配下の同 gate
で起動し、独立 env var は追加しない。gate OFF / 未設定 / 不正値では本機能導入前と完全に等価。

## 変更ファイル

| ファイル | 種別 | 内容 |
|---|---|---|
| `local-watcher/bin/modules/dep-cycle-detect.sh` | 新規 | `dc_*` prefix で cycle 検出・エスカレーション関数群（Tarjan SCC を awk iterative 実装） |
| `local-watcher/bin/issue-watcher.sh` | 変更 | `REQUIRED_MODULES` へ `dep-cycle-detect.sh` 追加 / `dr_unblock_sweep` から `dc_cycle_sweep` を呼び、cycle メンバーを auto-unblock 対象から除外 |
| `local-watcher/test/dc_cycle_sweep_test.sh` | 新規 | 74 テスト（AT-a 〜 AT-j を網羅） |
| `local-watcher/test/dr_unblock_sweep_test.sh` | 変更 | `dc_cycle_sweep` の no-op stub 追加（既存 56 テスト無影響、stderr 漏れ防止） |
| `README.md` | 変更 | ラベル状態遷移 / オプション機能一覧 / Dependency Auto-Unblock Sweep 節に cycle 検出を追記 |

## 設計判断（Open Questions の確定理由）

### Q1: 独立 env var か既存 `DEP_AUTO_UNBLOCK_ENABLED` 配下か → **既存 gate 配下に同居**

- 採用理由:
  - cycle 検出は #346 auto-unblock と密結合（cycle メンバーを auto-unblock 対象から除外する協調が必要 / Req 4.4, AT-j）
  - 取得済み `issues_json` を再利用すれば本文取得 API 追加呼び出しが 0 回（NFR 2.2）
  - 運用者の cognitive load 最小化（env var を 1 つ増やさない）
  - prompt 指示文「既存 gate ON 時に走るのを既定とする」と整合
- トレードオフ:
  - cycle 検出のみ無効化したい運用には対応できない（将来必要なら別 env var を `DC_CYCLE_DETECT_ENABLED` 等で追加可能）

### Q2: 閉路メンバー全員にコメント投稿 vs 代表 1 件のみ → **全員投稿**

- 採用理由:
  - 各メンバーの GitHub UI 履歴から「watcher cycle detection 由来」が独立に判別できる（NFR 4.2 監査性）
  - 代表 1 件のみだと他メンバー Issue から経緯を辿るために cross-reference が必要で運用者の認知コストが高い
  - 冪等性（Req 5.x）はマーカーで担保しているため、N 回スイープしても 1 回に収束する

### Q3: 閉路メンバー番号の表記順序 → **数値昇順**

- 採用理由:
  - 出力決定性が高くログ grep 検索しやすい（NFR 4.1）
  - Tarjan SCC の出力をそのままソートできる（実装複雑度を上げない）

### Q4: 説明コメントの本機能由来判定マーカー → **`<!-- idd-claude:dep-cycle-detected:v1 -->`**

- 採用理由:
  - 既存 `DR_UNBLOCK_MARKER_CLEARED` / `DR_UNBLOCK_MARKER_ORPHAN` と同パターン（`<!-- idd-claude:<name>:v1 -->`）
  - GitHub UI 上は不可視、grep / jq から検出可能（NFR 4.2 / Req 5.2）
  - `v1` バージョン suffix で将来形式変更時の互換性を確保

## アルゴリズム

- 閉路検出は Tarjan の SCC 分解を **awk iterative 実装** で書いた。
- SCC のうち以下を閉路として採用:
  - サイズ >= 2 の SCC（多ノード閉路 / Req 3.2, 3.3）
  - サイズ 1 の SCC かつ自己ループあり（A→A / Req 3.1）
- 計算量: O(V + E)（NFR 2.3）。awk 内部の連想配列で完結し bash global 汚染なし。
- 入力は `gh issue list --json number,body` 相当の JSON 配列で、cycle 検出は本文取得 API を追加で呼ばない（NFR 2.2）。

## 受入テスト対応表

| AC ID | 対応テスト（dc_cycle_sweep_test.sh） |
|---|---|
| Req 1.1 (gate ON) | `dc_gate_enabled: =true で gate ON` |
| Req 1.2 (gate OFF: 未設定/false) | `dc_gate_enabled: 未設定で gate OFF` / `=false は OFF` |
| Req 1.3 (gate 不正値正規化) | `=True / =1 は OFF に正規化` |
| Req 1.4 (signature 不変) | 既存 `dr_unblock_sweep_test.sh` 全 56 PASS（後方互換確認） |
| Req 1.5 (FULL_AUTO_ENABLED 評価) | `dr_unblock_sweep` 側で評価済（既存 #348） |
| Req 2.1 (対象集合 auto-dev+blocked+OPEN) | `dr_unblock_sweep` の既存検索フィルタを継承（既存テスト AT-i） |
| Req 2.2 (対象外エッジ除外) | `dc_extract_edges: 対象集合外 #999 は除外` / `dc_build_graph_lines: 対象集合外エッジ除外` |
| Req 2.3 (auto-unblock と協調起動) | `dr_unblock_sweep` 内で `dc_cycle_sweep` を sweep 本処理の前段で呼び出す（issue-watcher.sh:10238-10246） |
| Req 2.4 (空集合で追加 API ゼロ) | `dc_cycle_sweep: 空候補集合 → gh 呼び出しゼロ` |
| Req 3.1 (自己ループ検出) | `AT-b: 自己ループ #42→#42 → cycle {42}` / `dc_extract_edges: 自己ループ抽出` |
| Req 3.2 (任意長閉路検出) | `AT-c (2N)` / `AT-d (3N)` / `Req 3.2: 長さ 4 の閉路` |
| Req 3.3 (複数閉路区別) | `AT-f: 2 独立閉路` |
| Req 3.4 (閉路 + DAG 混在) | `AT-e: 混在` / `Req 3.4: 非閉路 DAG 部分は除外` |
| Req 3.5 (有限時間終了) | `Req 3.5: 空入力 → 空出力` + Tarjan O(V+E) の性質（NFR 2.3） |
| Req 4.1 (needs-decisions 付与) | `dc_escalate_member: 未通知 → needs-decisions 付与 1 回` |
| Req 4.2 (説明コメント投稿) | `dc_escalate_member: 未通知 → 説明コメント投稿 1 回` |
| Req 4.3 (マーカー含む) | `dc_format_cycle_comment: 本機能由来マーカー含む` / `NFR 4.2: 説明コメントにマーカー含む` |
| Req 4.4 (auto-unblock 除外) | `AT-j: _DC_CYCLE_MEMBERS に member 含む` + issue-watcher.sh の cycle-member skip 分岐 |
| Req 4.5 (ラベル失敗時 コメント skip) | `Req 4.5: ラベル付与失敗 → コメント投稿せず skip` |
| Req 4.6 (コメント失敗時 警告 + 次へ) | `AT-i / Req 4.6: コメント投稿失敗 → 警告ログ 1 行` |
| Req 5.1 (連続 N 回で 1 回収束) | `AT-g: 連続 2 回スイープ → 累積なし` |
| Req 5.2 (既通知 → 再投稿しない) | `Req 5.2: 通知済 → コメント投稿しない` |
| Req 5.3 (既ラベル → 付与しない) | `Req 5.3: 通知済 → ラベル付与 API 呼ばない`（マーカー検出で冪等） |
| Req 5.4 (構成不変で write ゼロ) | `AT-g 2 回目` + 既通知判定 |
| Req 6.1 (閉路検出ログ) | `Req 6.1 / NFR 4.1: 閉路ごとのログ 2 行` |
| Req 6.2 (ゼロ件ログ) | `Req 6.2: cycles=0 サマリログ 1 行以上` |
| Req 6.3 (エスカレーションログ) | `Req 6.3: verdict=cycle_escalated ログ 1 行` |
| Req 6.4 (冪等 skip ログ) | `Req 6.4: verdict=cycle_already_notified ログ 1 行` |
| Req 6.5 (gh 失敗 警告ログ) | `dc_escalate_member: ラベル付与失敗 → 警告ログ` |
| Req 7.1 (local-watcher のみ) | `repo-template/**` / `.claude/{agents,rules}/` への変更なし（diff -r 空確認） |
| Req 7.2 (README 更新) | README.md ラベル状態遷移 + オプション機能一覧 + Dependency Auto-Unblock Sweep 節 |
| Req 7.3 (依存記法ガイド不変) | `.claude/rules/issue-dependency.md` 変更なし |
| NFR 1.1 (gate OFF 完全等価) | `dr_unblock_sweep_test.sh` 56 PASS（既存挙動保証） + `dc_gate_enabled: 未設定で OFF` |
| NFR 1.2 (signature 不変) | 既存 dr_* 関数群を呼ぶのみで上書きしていない |
| NFR 2.1 (空集合で 1 クエリ) | `Req 2.4 / NFR 2.1: 空候補集合 → gh 呼び出しゼロ` |
| NFR 2.2 (本文取得 API 1 回以下) | `NFR 2.2: 本文取得 API 呼び出しゼロ`（`dr_unblock_sweep` の `gh issue list --json number,body` 1 回を再利用） |
| NFR 2.3 (多項式時間) | Tarjan SCC の O(V+E) 性質 |
| NFR 3.1 (空依存 → エッジ追加せず) | `NFR 3.1: 空依存のみ → ラベル付与ゼロ / _DC_CYCLE_MEMBERS 空` |
| NFR 3.2 (write 失敗で次へ) | `dc_escalate_member: ラベル付与失敗` / `コメント失敗` の警告分岐 |
| NFR 3.3 (cycle 優先 / auto-unblock 抑制) | issue-watcher.sh:10250-10258 の cycle-member skip 分岐 |
| NFR 4.1 (構造化ログ grep) | `dr:` プレフィックス継承 + `cycle=K members=...` 形式 |
| NFR 4.2 (本機能由来判別) | `DC_CYCLE_MARKER` HTML コメント |
| NFR 5.1 (未信頼入力安全) | `dc_normalize_targets` で `^[0-9]+$` フィルタ / `dc_escalate_member` で数値検証 / jq は `--arg/--argjson` で `make_issues_json` 経由 |
| NFR 5.2 (説明コメントに安全展開) | `dc_format_cycle_comment` でメンバー番号は数値検証済を `#N` 形式に整形 |
| NFR 6.1 (連続 2 回で 1 回収束) | `AT-g` |

## 受入テストカバレッジ

| AT-x | 状態 | 検証 |
|---|---|---|
| AT-a | DAG | `dc_find_cycles: AT-a: DAG → 閉路ゼロ` + `dc_cycle_sweep: AT-a: ラベル付与ゼロ` |
| AT-b | 自己依存 | `AT-b: 自己依存 → ラベル付与 1 回 / コメント 1 回` |
| AT-c | 2N 閉路 | `AT-c: A→B→A → 付与 2 回 / コメント 2 回` |
| AT-d | 3N 閉路 | `AT-d: A→B→C→A → 付与 3 回` |
| AT-e | 閉路 + 非閉路 | `AT-e: 閉路メンバーのみ対象（D, E は除外）` |
| AT-f | 複数独立閉路 | `AT-f: 2 独立閉路 → 4 メンバー全員付与` |
| AT-g | 連続 2 回 | `AT-g: 1 回目 → 付与 2 件 / 2 回目 → 付与ゼロ` |
| AT-h | gate OFF | `dc_gate_enabled` の 5 ケース（未設定 / =true / =True / =1 / =false） |
| AT-i | コメント失敗 | `AT-i / Req 4.6: コメント投稿失敗 → 警告ログ 1 行` |
| AT-j | auto-unblock 除外 | `AT-j: _DC_CYCLE_MEMBERS に member 含む` + watcher 本体の skip 分岐実装 |

## テスト結果

- `bash local-watcher/test/dc_cycle_sweep_test.sh` → **PASS 74 / FAIL 0**
- `bash local-watcher/test/dr_unblock_sweep_test.sh` → **PASS 56 / FAIL 0**（既存 / 後方互換確認）
- 全テストファイル `local-watcher/test/*_test.sh` → **OVERALL 0（all pass）**
- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh local-watcher/test/dc_cycle_sweep_test.sh` → 警告ゼロ
  - 既存 `local-watcher/test/dr_unblock_sweep_test.sh` の SC2034（line 111: `FULL_AUTO_ENABLED="true"`）は **本変更前から存在する pre-existing baseline**（変更前: line 99 で同警告）であり、`.shellcheckrc` の info 抑止対象ではない別 warning。本 PR で新規発生していないため accepted baseline として扱う
- `actionlint .github/workflows/*.yml` → 警告ゼロ
- `bash -n local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/dep-cycle-detect.sh local-watcher/test/dc_cycle_sweep_test.sh` → 構文 OK
- watcher boot smoke test: `REPO=owner/test REPO_DIR=/tmp/test-no-such bash local-watcher/bin/issue-watcher.sh` → モジュールロード成功、startup ログ正常出力

## 同期確認

- `diff -r .claude/agents repo-template/.claude/agents` → 空
- `diff -r .claude/rules repo-template/.claude/rules` → 空
- 本機能は requirements の Req 7.1 / 7.3 通り `repo-template/**` / `.claude/{agents,rules}/` への変更を伴わない（`local-watcher/` のみで完結）

## 後続課題 / 派生タスク候補

- **cycle 検出のみを独立 env で無効化する運用**: 将来必要になった場合は `DC_CYCLE_DETECT_ENABLED` を導入して二段ゲートに拡張可能（現状は不要）。
- **閉路解消の自動提案**: Out of Scope 通り本 PR では扱わない。将来 cycle メンバーへ「どのエッジを切れば閉路解消するか」のヒントを生成する機能を別 Issue で検討してもよい。
- **PR / 設計 PR ↔ Issue 間の依存記法**: 現在は Issue 本文の `Depends on:` / `前提依存:` / `Blocked by:` のみを抽出対象とする（既存 `dr_extract_deps` の挙動を継承）。PR 本文経由の依存は対象外。

## 確認事項

- なし（要件・設計の解釈に曖昧さなし。Open Questions は本ノート「設計判断」節で確定）。
