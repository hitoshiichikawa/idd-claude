# Implementation Notes (#379)

## Implementation Notes

### Task 1

採用方針: Config ブロック直後に `sr_is_enabled` を暫定実装（task 2 で module へ移送予定）。failed-recovery の二重 opt-in（Req 1.x）と異なり Stale Pickup Reaper は単独 gate（`STALE_PICKUP_REAPER_ENABLED=true` 厳密一致）のみで起動する（design.md "FULL_AUTO_ENABLED 配下に置くか単独 gate か" の判定根拠 1〜3 / Req 1.1〜1.4）。

重要な判断:
- **暫定配置**: `sr_is_enabled` を `issue-watcher.sh` の Config ブロック直後に置く方針は task 1 仕様の明示要件。task 2 で `modules/stale-pickup-reaper.sh` を新規作成する際にここから移送する（暫定実装である旨をコメントで明示済み）。`extract_function` イディオムでテストから切り出せるよう、トップレベル副作用なしの関数定義のみとした
- **Config 正規化方針**: 4 つの数値 env（`THRESHOLD_MINUTES` / `MAX_ISSUES` / `GH_TIMEOUT`）は `case '' | *[!0-9]*` で非整数を検出し、`-le 0` で 0 以下を弾く `failed-recovery` (#359) と同パターン。`ENABLED` は `case`/`true`/`*` の 2 分岐で「true 厳密一致以外は false」へ正規化する simple gate
- **logger 配置**: `sr_log` / `sr_warn` / `sr_error` は `fr_log` 直後（行 159 付近）に追加。prefix `stale-pickup` + `[$REPO]` 3 段で grep 検索性を維持
- **「デフォルト有効化フラグの値正規化」ループに含めない**: 既定 false の新規 opt-in のため、`#112` の 8 種既定 true 反転対象とは別軸（failed-recovery と同方針）

残存課題:
- task 2 で `modules/stale-pickup-reaper.sh` を新規作成し、暫定配置した `sr_is_enabled` をそこへ移送する必要がある。移送時は `issue-watcher.sh` 側から本関数定義ブロックを **削除**して module 側へ移し、`REQUIRED_MODULES` 順 source 後に `declare -F sr_is_enabled` が成立することを確認する（task 6 の本体配線で `REQUIRED_MODULES` への登録を行う）
- task 1 時点ではテスト fixture が `extract_function "$WATCHER_SH" "sr_is_enabled"` で本体から切り出している。task 2 移送後は `MODULE_SH="$SCRIPT_DIR/../bin/modules/stale-pickup-reaper.sh"` 側から抽出する形に変更する必要がある（移送 task で同時に test fixture も更新する）

### Task 2

採用方針: `modules/stale-pickup-reaper.sh` を新規作成し、task 1 で本体に暫定配置していた `sr_is_enabled` と新規 3 関数（`sr_marker_path` / `sr_load_marker` / `sr_save_marker`）を集約。失敗時 fail-open（`{}` 返却）+ atomic write（mktemp → mv -f）+ `jq --arg`/`--argjson` 全引数 sanitize の三本柱で永続化レイヤを構築（`fr_state_path` / `fr_load_state` / `fr_save_state` と同型）。

重要な判断:
- **module 冒頭コメントを `failed-recovery.sh` と同パターンに統一**: 用途 / 配置先 / 依存 / セットアップ参照先の 4 ブロック構成。`set -euo pipefail` を宣言しない / `sr_log` / `sr_warn` / `sr_error` は再定義しない（core_utils.sh 集約）旨も明記し、後続 task で同 module に関数追加するときの規約が一目で分かる形にした
- **`sr_is_enabled` の本体側削除と Config 直後コメント差替え**: 本体側の関数定義ブロックを完全削除し、Config ブロック直後に「`sr_is_enabled` / 永続化レイヤは module に集約」「`REQUIRED_MODULES` 登録は task 6」とだけ書いた短コメントへ差し替え。Config 正規化ブロック（5 env）は task 1 の通り温存
- **labels_json の空文字 fail-safe**: 呼出側が空文字を渡したケース（後続 task で初回観測時に `[]` を渡し忘れる事故等）を想定し、`sr_save_marker` 内で空文字 → `[]` 正規化を 2 段防御（`-n` テストで空チェック / jq 結果の空チェック）にした。`jq` は空入力に対して rc=0 + 空出力を返すため、空出力を素通すと後続 `--argjson last_known_labels ""` が失敗する罠を回避
- **test 抽出元の切替**: `extract_function "$WATCHER_SH" "sr_is_enabled"` を `extract_function "$MODULE_SH" "sr_is_enabled"` へ変更し、新規 3 関数も同 module から抽出。`MODULE_SH` 不在検証ブロックを `WATCHER_SH` のものと同パターンで追加
- **Section 6 jq sanitize 検証**: `"`, `\`, `$`, `` ` ``, 改行 を含む値で injection が起きずに literal 保持されることを 4 field（first_seen_at / last_seen_at / status / revert_at）について確認。`labels_json` 要素中の特殊文字（`"with\\backslash`）も literal 保持を確認

残存課題:
- task 3 で `sr_fetch_candidates`（gh API filter）を実装する際、本 task の `sr_save_marker` が要求する 4 引数（first_seen_at / last_seen_at / labels_json / status / revert_at）を呼出側から正しく生成する必要がある。`labels_json` は `gh issue list --json labels` の出力を `jq -c '[.labels[].name]'` で配列文字列化して渡すのが自然
- task 5 で `process_stale_pickup_reaper` orchestrator から本 layer を呼ぶときに、observing → reverted 状態遷移を `sr_save_marker` の `status` / `revert_at` 引数の組で表現することを確認した（observing 時は `revert_at=""`、reverted 時は `revert_at=<now ISO 8601>`）

### Task 3

採用方針: `sr_fetch_candidates` を `modules/stale-pickup-reaper.sh` 末尾の新規 `Candidate Selection Layer` セクションに追加し、`failed-recovery.sh` の `fr_fetch_failed_issues` と同型の 4 段ガード（timeout / JSON 検証 / 空入力 / 非 array fallback）を踏襲。`gh --search` の `label:"A" OR label:"B"` 構文は server-side で安定しないため、`claude-picked-up` / `claude-claimed` の **2 クエリを個別発行** → `jq` の `unique_by(.number)` で結合 + dedup する設計（design.md "API Contract" 節 + tasks.md task 3 仕様に準拠 / Req 2.1, 2.2, 2.5）。

重要な判断:
- **`hold` ラベルは literal 文字列で扱う**: tasks.md / design.md 双方が `-label:"hold"` を literal で記述しており、`LABEL_HOLD` 定数は本体 `issue-watcher.sh:59-97` に存在しないため新規 LABEL 定数を追加せず literal で渡す方針を採用（grep 確認済み / 新規 LABEL 定数追加は禁止 / CLAUDE.md「機能追加ガイドライン §3」の後方互換規約と整合）。それ以外の除外ラベル（`claude-failed` / `needs-decisions` / `awaiting-design-review` / `needs-quota-wait` / `blocked` / `staged-for-release`）は既存 `LABEL_*` 定数を参照する
- **2 クエリ分離 + jq 結合の選択**: `failed-recovery.sh` は単一クエリで `label:"A" label:"B"` の AND だけを使うため 1 クエリ完結だが、SPR は **2 ラベルの OR** を扱う必要があり、`gh --search` の OR / 単一 search 内 union が server-side で安定しないため別クエリ + client-side dedup（jq `unique_by(.number)`）の方式を採用した。design.md の "API Contract" 節も `gh issue list --search "label:\"<picked\|claimed>\""` の擬似記法で 2 クエリ展開を前提とする
- **truncate は jq 側で `.[0:N]`**: `--limit "$STALE_PICKUP_REAPER_MAX_ISSUES"` を各クエリに付けても 2 クエリ合算で 2N まで膨れるため、結合後に jq `.[0:$limit]` で最終 truncate する（NFR 1.2 の上限契約を完全準拠）。`--argjson limit` 経由で sanitize（NFR 3.1）
- **stub テストで `gh` / `timeout` を関数化**: `failed-recovery.sh` も含め、本体は `timeout <sec> gh ...` で直接呼ぶ実装パターンのため、bash 関数として `timeout()` / `gh()` を test fixture で定義することで stub 可能になる。tasks.md 仕様の「`timeout()` も関数定義する形」を採用し、production コードに `${SR_TIMEOUT_CMD:-timeout}` のような間接呼び出しを入れない（既存 `fr_fetch_failed_issues` と同じ直接呼び出しパターンを温存）
- **gh stub の stdout / trace 分離**: 初回実装で関数定義レベル `} >> "$SR_GH_TRACE"` で stdout 全体を redirect していたため、`cat "$SR_GH_PICKED_RESPONSE"` の出力も trace 側に流れて caller `$(gh ...)` が空文字を受け取る trap に遭遇。trace 書き込みは `{ printf ...; } >> "$SR_GH_TRACE"` のブロック単位で隔離する形に修正し、関数本体の stdout は JSON response として保つ構造に整理した

残存課題:
- task 4 で `sr_check_marker_age` / `sr_check_slot_lock` / `sr_check_session` / `sr_is_active` を実装する際、本 task の `sr_fetch_candidates` が返す JSON の各要素（`{number, labels, title, url, updatedAt}`）から marker.last_known_labels 更新値を生成する必要がある。`jq -c '[.labels[].name]'` で配列文字列化して `sr_save_marker` の第 4 引数に渡すパターンが自然
- task 5 の `process_stale_pickup_reaper` orchestrator から本関数を呼ぶときに、`STALE_PICKUP_REAPER_GH_TIMEOUT` の Config 正規化（task 1 で `--state open` / `--repo` と共に確立済み）が呼び出し時点で解決されることを確認した（遅延束縛 / `sr_marker_path` と同パターン）

## AC Traceability（task 3 範囲）

| AC | テスト | 場所 |
|----|--------|------|
| Req 2.1 | search 文字列に `label:"claude-picked-up"` 含む | `local-watcher/test/stale_pickup_reaper_test.sh:Section 7a` |
| Req 2.2 | search 文字列に `label:"claude-claimed"` 含む | 同上 Section 7a |
| Req 2.3 | 人間判断待ち 6 ラベル（needs-decisions / awaiting-design-review / needs-quota-wait / blocked / staged-for-release / hold）の `-label:"..."` 除外を search に含む | 同上 Section 7a（6 ラベル個別 assert） |
| Req 2.4 | `-label:"claude-failed"` 除外を search に含む（failed-recovery 領分との分離） | 同上 Section 7a |
| Req 2.5 | 2 クエリ結合後 jq `unique_by(.number)` で dedup（#100 重複が 1 件に集約）+ server-side filter のみ使用 | 同上 Section 7a（dedup 3 件 assert） |
| NFR 1.2 | `--repo owner/test-repo` / `--state open` / `--limit 20` / `--json number,labels,title,url,updatedAt` の伝達 / `STALE_PICKUP_REAPER_MAX_ISSUES=5` で動的反映 | 同上 Section 7a + 7e |
| NFR 3.1 | 既存 `LABEL_*` 定数参照 / jq `--argjson limit` 経由（literal 展開しない） | 同上 Section 7a（label 文字列が定数値と一致） |
| NFR 5.2 | gh 失敗（rc≠0）/ 非 JSON 出力 / 空文字で `[]` + `sr_warn` 1 行以上 + rc=0（fail-continue） | 同上 Section 7b / 7c / 7d |
| 設計 timeout | `timeout 60` で gh 呼び出しを保護（`STALE_PICKUP_REAPER_GH_TIMEOUT` 反映） | 同上 Section 7a（SR_TIMEOUT_TRACE 検証） |

## 検証コマンド（task 3 範囲）

```sh
shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/core_utils.sh local-watcher/test/stale_pickup_reaper_test.sh
bash -n local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/stale-pickup-reaper.sh
bash local-watcher/test/stale_pickup_reaper_test.sh   # 116 assertions PASS
bash local-watcher/test/fr_state_test.sh              # 51 assertions PASS（regression）
diff -r .claude/agents repo-template/.claude/agents   # 空
diff -r .claude/rules repo-template/.claude/rules     # 空
```

## AC Traceability（task 1 範囲）

| AC | テスト | 場所 |
|----|--------|------|
| Req 1.1 | `ENABLED=true で rc=0` | `local-watcher/test/stale_pickup_reaper_test.sh:Section 1` |
| Req 1.2 | `ENABLED=false / 未設定で rc=1` | 同上 Section 1 + Section 0 (`bash -c` 直接検証) |
| Req 1.3 | `True / TRUE / 1 / on / yes / typo / 空白で rc=1` | 同上 Section 1 + Section 0 (normalize_enabled) |
| Req 1.4 | env / stdout / stderr 副作用なし | 同上 Section 1b |
| Req 4.1 | THRESHOLD 既定 45 (未設定) | 同上 Section 0 (`bash -c` 直接検証) |
| Req 4.3 | THRESHOLD 不正値 → 45 | 同上 Section 0 (normalize_threshold) |
| Req 4.4 | THRESHOLD 正常整数はそのまま | 同上 Section 0 (normalize_threshold) |
| NFR 1.1 | gate OFF 既定で env 副作用なし | 同上 Section 1 (未設定 rc=1) / Section 0 (`bash -c` 既定 false) |
| NFR 1.3 | gate OFF で stderr 副作用ゼロ | 同上 Section 1b |

## AC Traceability（task 2 範囲）

| AC | テスト | 場所 |
|----|--------|------|
| Req 5.5 | save → load 往復で schema 全 field（issue / first_seen_at / last_seen_at / last_known_labels / status / revert_at）保持 / 状態遷移（observing → reverted） | `local-watcher/test/stale_pickup_reaper_test.sh:Section 3` |
| NFR 2.2 | 不在ファイルで `{}` fail-open / 再読込で値継承 | 同上 Section 5（不在 / 破損 fail-open） |
| NFR 2.3 | atomic rename（中間 tmp file 不残存） / ネスト dir 自動作成 / 破損ファイル後の救済 save | 同上 Section 4 + Section 5 |
| NFR 3.1 | jq `--arg` / `--argjson` 全引数 sanitize（`"` / `\` / `$` / `` ` `` / 改行 / labels 要素中の特殊文字） | 同上 Section 6 |
| 設計 sr_marker_path | 絶対パス算出 / state dir 切替で追従（遅延束縛） | 同上 Section 2 |

## 検証コマンド（task 2 範囲）

```sh
shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh local-watcher/bin/issue-watcher.sh local-watcher/test/stale_pickup_reaper_test.sh
bash -n local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/stale-pickup-reaper.sh
bash local-watcher/test/stale_pickup_reaper_test.sh   # 91 assertions PASS
bash local-watcher/test/fr_state_test.sh              # 51 assertions PASS（regression）
```

## 確認事項

なし（task 2 / task 3 仕様内で完結 / 既存仕様との整合性確認済み）。

STATUS: complete
