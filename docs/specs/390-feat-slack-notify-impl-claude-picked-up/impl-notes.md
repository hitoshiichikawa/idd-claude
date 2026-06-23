# Implementation Notes — Issue #390

## 変更ファイル一覧

| Path | 変更概要 |
|---|---|
| `local-watcher/bin/modules/slack-notify.sh` | event_type enum に `claude-pickup` を追加（line 118）。モジュール冒頭コメントの「重要イベント 5 → 6」化、`sn_build_payload` Args コメントの enum 列挙更新、`sn_notify` Args コメントの「5 値 → 6 値」更新 |
| `local-watcher/bin/issue-watcher.sh` | impl/impl-resume の `claude-claimed → claude-picked-up` 付け替え成功直後（既存 `slot_log "ラベル付け替え..."` の次行）に `sn_notify claude-pickup ... \|\| true` を 1 行追加 |
| `local-watcher/test/sn_build_payload_test.sh` | Section 2 末尾に `claude-pickup` の正常系テスト 5 件を追加（well-formed JSON / event_type 含有 / Issue 番号 / Issue URL / detail 内 mode 識別子）。Section 3 の有効 event_type ループに `"claude-pickup"` を追加 |
| `README.md` | line 1500 の Slack 通知 emitter 行を「重要イベント 5 → 6 種」「通知対象 5 → 6 イベント」へ更新。列挙末尾に `claude-pickup`（impl 着手 / #390）を追加 |

二重管理同期は対象外（`.claude/{agents,rules}` の改変なし、`repo-template/` 配下も改変なし。`slack-notify.sh` は `local-watcher/bin/modules/` のみが正本、consumer 側は `install.sh` 経由配布）。

## AC ↔ 実装 / テスト Traceability

| Req | AC 概要 | 実装箇所 | テスト |
|---|---|---|---|
| 1.1 | ラベル付け替え成功直後に `claude-pickup` 通知 1 通 | `local-watcher/bin/issue-watcher.sh:10954` | （副作用テストは無し / `sn_notify` 単体検証は #370 既存テスト） |
| 1.2 | `MODE=impl` または `impl-resume` の状態で発火 | `local-watcher/bin/issue-watcher.sh:10945`（既存 if 分岐）の内側に配置 | （同上） |
| 1.3 | ラベル付け替え失敗時は通知しない | `local-watcher/bin/issue-watcher.sh:10946-10952`（失敗時 `return 1` で sn_notify 行に到達せず） | （同上） |
| 1.4 | 再 pickup（impl-resume）でも遷移ごとに 1 通 | sn_notify は state を持たず、呼び出し毎に 1 通発火する設計（#370 既存仕様） | （同上） |
| 2.1 | payload に Issue 番号を含む | `sn_build_payload` の `text` / `blocks` に `$number` が埋め込まれる（#370 既存 / unchanged） | `sn_build_payload_test.sh` Section 2 #390 Req 2.1 |
| 2.2 | payload に Issue URL を含む | `sn_build_payload` の `text` / `blocks` に `$url` が埋め込まれる（#370 既存 / unchanged） | `sn_build_payload_test.sh` Section 2 #390 Req 2.2 |
| 2.3 | payload に mode 識別子を含む | callsite で `detail="mode=${MODE} slot=${IDD_SLOT_NUMBER}"` を渡す。`sn_build_payload` が detail を `blocks[0].text.text` に含める | `sn_build_payload_test.sh` Section 2 #390 Req 2.3（`mode=impl` を block_text に確認） |
| 2.4 | 既存 callsite 規約に整合 | `sn_notify claude-pickup "<num>" "<url>" success "<detail>" \|\| true` の 5 引数形（auto-merge.sh:180 / needs-decisions-auto.sh:258 / promote-pipeline.sh:1716 と同形） | （callsite シグネチャ目視） |
| 3.1 | `claude-pickup` を有効 event_type として受理 | `slack-notify.sh:118` の case 文に追加 | `sn_build_payload_test.sh` Section 3 列挙ループ（`event_type=claude-pickup は受理される`） |
| 3.2 | エラー終了せず正常 payload を生成 | 同上（rc=0 で payload を stdout） | `sn_build_payload_test.sh` Section 2 #390 Req 3.2 (`well-formed JSON`) |
| 3.3 | 既存 5 イベントの受理性・payload 構造・既存テスト合格を維持 | enum case 文への追記のみで既存 5 値の評価は不変 | Section 3 既存 5 値ループ + Section 2 既存 auto-merge 系テストが全 PASS |
| 4.1 | gate OFF 時は通知を送信しない | `sn_notify` の `sn_is_enabled` 早期 return（#370 既存・unchanged） | （#370 既存テスト範囲。本 PR では touch せず） |
| 4.2 | gate ON 時は Req 1 条件下で送信 | callsite 1 行追加で発火動線確保 | (副作用 E2E は dogfooding 確認に委譲) |
| 4.3 | 通知失敗で後続処理をブロックしない | `sn_notify` 内部で全失敗を fail-open 化 + callsite 側 `\|\| true` 二重防御 | sn_notify 戻り値仕様（#370 既存）+ callsite 末尾 `\|\| true` 目視 |
| 4.4 | 既存 5 イベントと同じ fail-open 挙動 | sn_notify 共通実装に乗せたため自動的に同等 | （同上） |
| 5.1 | 新規 env var を追加せず既存を流用 | `SLACK_NOTIFY_ENABLED` / `SLACK_WEBHOOK_URL` / `SLACK_NOTIFY_TIMEOUT` のみ参照、新規導入なし | `git diff` 確認: 新 env キーワード追加なし |
| 5.2 | 新規関数 prefix を導入せず `sn_` 内 | 新規関数を作らず `sn_notify` を呼ぶだけ | （目視） |
| 5.3 | 既存ラベル名・遷移契約・exit code を変更しない | ラベル付け替え分岐 (`gh issue edit --remove-label / --add-label`) は touch せず、後追いで sn_notify を 1 行足しただけ | （差分目視） |
| 5.4 | 既存 5 callsite を改変しない | `auto-merge.sh` / `auto-merge-design.sh` / `needs-decisions-auto.sh` / `promote-pipeline.sh` / `failed-recovery.sh` を touch せず | `git diff` で当該 5 ファイル変更ゼロを確認 |
| NFR 1.1 | shellcheck 警告ゼロ維持 | 既存スタイルで追加（quote / 既存 baseline 範囲内） | `shellcheck` 全 3 ファイル exit 0 |
| NFR 1.2 | actionlint クリーン維持 | workflow 変更なし | （変更なしのため non-regression） |
| NFR 1.3 | 既存テストが claude-pickup を有効 enum として受理し合格 | enum case + Section 3 ループ更新 | `sn_build_payload_test.sh` 50/50 PASS |
| NFR 1.4 | 既存 5 イベントテストを破壊しない | 既存ケースに変更なし、追記のみ | 既存全ケース PASS（Section 3 既存 5 値ループ含む） |
| NFR 2.1 | README の件数記述更新 | `README.md:1500` を 5 → 6 へ更新、`claude-pickup` を列挙 | （差分目視） |
| NFR 2.2 | モジュール冒頭コメント・enum 列挙箇所を更新 | `slack-notify.sh` 冒頭 / `sn_build_payload` Args / `sn_notify` Args / case 文 4 箇所更新 | （差分目視） |
| NFR 3.1 | 既存タイムアウト境界内で完了 | sn_notify 共通実装に乗せたため自動的に同等 | （#370 既存仕様） |
| NFR 3.2 | 1 遷移 = 1 通（重複発火なし） | callsite が if ブロック内で 1 回のみ実行される位置に配置 | （差分目視 / 既存 callsite と同形パターン） |

## 検証結果

### 1. bash 構文チェック

```
$ bash -n local-watcher/bin/modules/slack-notify.sh \
  && bash -n local-watcher/bin/issue-watcher.sh \
  && bash -n local-watcher/test/sn_build_payload_test.sh
bash -n: OK
```

### 2. shellcheck

```
$ shellcheck local-watcher/bin/modules/slack-notify.sh \
  local-watcher/bin/issue-watcher.sh \
  local-watcher/test/sn_build_payload_test.sh
shellcheck: OK
```

`.shellcheckrc` の accepted baseline（`SC2317` / `SC2012` 抑止）範囲内で警告ゼロ。新規警告なし。

### 3. 既存テスト

```
$ bash local-watcher/test/sn_build_payload_test.sh
...
RESULT: PASS=50 FAIL=0
```

exit code 0。50 件 PASS / 0 件 FAIL。

### 4. claude-pickup enum 受理確認

テスト出力に以下の PASS 行が含まれることを確認:

- `PASS: Req 3.1: event_type=claude-pickup は受理される`（Section 3 enum ループ）
- `PASS: #390 Req 3.2: claude-pickup payload が well-formed JSON`（Section 2 #390 拡張）
- `PASS: #390 Req 3.1: payload に event_type=claude-pickup を含む`（同上）
- `PASS: #390 Req 2.1: payload に Issue 番号 #390 を含む`
- `PASS: #390 Req 2.2: payload に Issue URL を含む`
- `PASS: #390 Req 2.3: detail 内に mode 識別子（mode=impl）を含む`

## 確認事項

なし。Open Questions も requirements.md 上で「なし」と明示済み。

## Implementation Notes

### Task 390-1（単一 task）

- **採用方針**: 既存 5 イベントと完全に同形の callsite + enum 1 値追加 + コメント・README の件数同期。新規 env / prefix / 関数を作らず最小差分。
- **重要な判断**:
  - callsite 位置は `slot_log "ラベル付け替え..."` 直後（既存 if ブロック内）に固定。ラベル付け替え失敗時は早期 `return 1` で sn_notify 行に到達しない（Req 1.3 構造的担保）。
  - `detail` を `"mode=${MODE} slot=${IDD_SLOT_NUMBER}"` 形式にし、payload の `blocks[0].text.text` 経由で mode 識別子を Slack 受信者に届ける（Req 2.3）。
  - `|| true` の二重防御: `sn_notify` 自体が fail-open で常に rc=0 を返すが、`set -euo pipefail` 配下での future-proof 防御として既存 callsite 全 5 件と同形で `|| true` を付与。
- **残存課題**: なし（本 task で全 AC をカバー）。

STATUS: complete
