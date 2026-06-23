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

なし（task 2 仕様内で完結 / 既存仕様との整合性確認済み）。

STATUS: complete
