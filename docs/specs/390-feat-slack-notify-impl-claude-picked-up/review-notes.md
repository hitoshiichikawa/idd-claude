# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T09:21:32Z -->

## Reviewed Scope

- Branch: claude/issue-390-impl-feat-slack-notify-impl-claude-picked-up
- HEAD commit: f84cad44760004fd8adbaab81ec593d05b9716d1
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/slack-notify.sh` / `local-watcher/bin/issue-watcher.sh` / `local-watcher/test/sn_build_payload_test.sh` / `README.md` / `docs/specs/390-*/`（requirements / impl-notes）

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh:10954` の `slot_log "ラベル付け替え..."` 直後で `sn_notify claude-pickup ... || true` を 1 行発火（既存ラベル付け替え if ブロック内）
- 1.2 — 当該 callsite は impl / impl-resume の `_slot_run_issue` の MODE 分岐内側に配置（既存 if 条件にぶら下がる位置）
- 1.3 — ラベル付け替え失敗時の早期 `return 1`（10946-10952 周辺）により sn_notify 行へ到達しない構造で担保
- 1.4 — `sn_notify` は内部状態を持たず呼び出しごとに 1 通発火（既存 #370 仕様 / impl-resume 経路でも同 callsite を通る）
- 2.1 — `sn_build_payload_test.sh` Section 2 拡張: `#390 Req 2.1: payload に Issue 番号 #390 を含む`
- 2.2 — 同上: `#390 Req 2.2: payload に Issue URL を含む`
- 2.3 — 同上: `#390 Req 2.3: detail 内に mode 識別子（mode=impl）を含む`（callsite で `detail="mode=${MODE} slot=${IDD_SLOT_NUMBER}"` を渡し、`blocks[0].text.text` 経路で payload へ反映）
- 2.4 — callsite シグネチャは既存 5 イベント callsite（auto-merge.sh / needs-decisions-auto.sh / promote-pipeline.sh 等）と同形の `sn_notify <event> <num> <url> <result> <detail>` 5 引数
- 3.1 — `slack-notify.sh:118` の case 文に `|claude-pickup` を追加（enum 受理）
- 3.2 — Section 2 追加テスト `#390 Req 3.2: claude-pickup payload が well-formed JSON`（jq -e で検証）
- 3.3 — Section 3 enum ループに `claude-pickup` を追加。既存 5 値（auto-merge / auto-merge-design / failed-recovery / needs-decisions-auto-continue / promote）の評価は case 文の OR 拡張のみで unchanged。impl-notes に 50/50 PASS と記録
- 4.1 — `sn_notify` 内部の `sn_is_enabled` 早期 return が既存実装で担保（unchanged）
- 4.2 — gate ON 時は callsite 1 行追加で Req 1 条件下に発火動線確保
- 4.3 — `sn_notify` 内部 fail-open + callsite 側 `|| true` の二重防御で pickup 後の後続処理（ブランチ作成等）をブロックしない
- 4.4 — sn_notify 共通実装に乗せたため既存 5 イベントと同じ fail-open 挙動
- 5.1 — diff に新規 env キー追加なし（`SLACK_NOTIFY_ENABLED` / `SLACK_WEBHOOK_URL` / `SLACK_NOTIFY_TIMEOUT` のみ流用）
- 5.2 — 新規関数追加なし、`sn_notify` を呼ぶだけ。`sn_` namespace 内
- 5.3 — ラベル付け替え分岐自体は touch せず、後追いで 1 行追加。既存ラベル名・遷移契約・exit code 不変
- 5.4 — `git diff --stat` 確認: 既存 5 callsite ファイル（auto-merge.sh / auto-merge-design.sh / needs-decisions-auto.sh / promote-pipeline.sh / failed-recovery.sh）は変更ゼロ
- NFR 1.1 — impl-notes に `shellcheck: OK` 記録（accepted baseline 範囲内）
- NFR 1.2 — workflow YAML 変更なし（actionlint non-regression）
- NFR 1.3 — Section 3 enum ループに claude-pickup 追加で受理確認
- NFR 1.4 — 既存 Section 2 / Section 3 テストケースは追加のみで破壊なし（50/50 PASS）
- NFR 2.1 — `README.md:1500` の Slack 通知 emitter 行を「5 イベント → 6 イベント」に更新、列挙末尾に `claude-pickup` 追記
- NFR 2.2 — `slack-notify.sh` 冒頭コメント / `sn_build_payload` Args / `sn_notify` Args の 4 箇所 + case 文を同 PR 内で更新
- NFR 3.1 — sn_notify 共通実装に乗せたため既存タイムアウト境界（`SLACK_NOTIFY_TIMEOUT`）を継承
- NFR 3.2 — callsite が if ブロック内に 1 回のみ配置されており、1 遷移につき 1 通発火

## Findings

なし

## Summary

`claude-pickup` の event_type enum 追加、issue-watcher.sh のラベル付け替え直後への callsite 1 行追加、payload 検証テスト 5 件 + Section 3 enum ループ拡張、README / モジュール冒頭コメントの件数同期がすべて整合的に行われており、Requirement 1〜5 と NFR 1〜3 を全カバー。既存 5 イベント callsite / 既存テスト / 新規 env var ゼロで後方互換性も担保。境界逸脱なし。

RESULT: approve
