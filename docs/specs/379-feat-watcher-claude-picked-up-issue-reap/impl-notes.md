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

## 検証コマンド（task 1 範囲）

```sh
shellcheck local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh
bash -n local-watcher/bin/issue-watcher.sh
bash local-watcher/test/stale_pickup_reaper_test.sh   # 52 assertions PASS
```

## 確認事項

なし（task 1 仕様内で完結）。

STATUS: complete
