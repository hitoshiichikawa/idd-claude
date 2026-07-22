# 実装ノート — #507 Triage complexity 判定と size ラベル永続化（Phase 1）

> 分量が目安（120 行）を超過している理由: AC が 63 件あり Traceability 表が長いこと、および
> tasks.md 7 が要求する手動スモーク手順の実出力記録を含むため。

## タスクごとの実装内容

| # | 内容 | 主な成果物 |
|---|---|---|
| 1 | `size:small` / `size:medium` / `size:large` を labels script 2 系統へ additive parity で追加 | `.github/scripts/idd-claude-labels.sh` / `repo-template/...` 各 +3 行（既存行の変更 0） |
| 2 | Triage 出力へ `complexity` / `complexity_reason` を additive 追加し、判定基準節を新設 | `local-watcher/bin/triage-prompt.tmpl` |
| 3 | 新規 module（prefix `mr_` / 関数定義のみ）と近接テストを追加 | `local-watcher/bin/modules/model-router.sh`, `local-watcher/test/model_router_test.sh` |
| 4 | gate 宣言と module ローダ登録 | `watcher-config.sh`（`MODEL_ROUTING_ENABLED`）, `issue-watcher.sh`（`REQUIRED_MODULES`） |
| 5 | Triage 消費部への call site 配線（Phase E ブロック直後 / needs-decisions 分岐より前） | `local-watcher/bin/modules/slot-worker.sh` |
| 6 | 運用ドキュメント更新 | `README.md`（ツリー / opt-in 表 / 新規節）, `CLAUDE.md`（prefix 表） |
| 7 | 最終検証（静的解析 / 近接テスト / parity 抽出比較 / 同期 diff / 手動スモーク） | 本ノート |

関数の契約（rc 0〜5 / 引数 / ログ）は `model-router.sh` のヘッダコメントと各関数コメントに
記載した（design.md「戻り値契約」表と 1:1）。

## 設計との差異・判断

1. **Triage prompt の JSON 例で `edit_paths` 閉じ括弧に `,` が付いた**（1 行の削除差分）。
   末尾追加に伴う JSON 構文上の必然で、既存 6 keys の位置・型・意味は不変（Req 2.1 充足）。
   キー行そのものへの差分は 0 行であることを `git diff` で確認済み。
2. **JSON 例の union 表記**（`"small" | "medium" | "large"`）は既存 `status` /
   `needs_architect` / `classification` と同じスキーマ記法に揃えた。そのままでは jq に通らない
   ため、検証は union を具体値へ置換してから `jq .` に通す形で行った（下記検証ログ参照）。
3. **`size:` prefix リテラルの局所化**: 実装当初 `mr_persist_size_label` が
   `mr_has_size_label` へ prefix を明示的に渡しており literal が 3 箇所に出現していたため、
   design.md「実装方針メモ」の指定どおり 2 箇所（既定引数 / ラベル名構成部）へ寄せた
   （commit `821e6e5` / 挙動不変）。
4. **依存ライブラリの追加なし**（`gh` / `jq` は既存必須 CLI）。`install.sh` は
   `modules/*.sh` を glob 配布するため installer 変更も不要（design.md の裏取りどおり）。

## 検証コマンドと結果

### tasks.md `## Verify` の構造化ブロック全体

```
$ shellcheck local-watcher/bin/modules/model-router.sh local-watcher/bin/modules/slot-worker.sh \
    local-watcher/bin/watcher-config.sh local-watcher/bin/issue-watcher.sh \
    .github/scripts/idd-claude-labels.sh && \
  bash -n local-watcher/bin/modules/model-router.sh && \
  bash local-watcher/test/model_router_test.sh && \
  diff <(grep -E '^[[:space:]]*"size:(small|medium|large)\|' .github/scripts/idd-claude-labels.sh) \
       <(grep -E '^[[:space:]]*"size:(small|medium|large)\|' repo-template/.github/scripts/idd-claude-labels.sh) && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
=== verify ブロック全体の exit code: 0 ===   （shellcheck 警告ゼロ / diff 出力なし）
```

### 近接テスト

```
$ bash local-watcher/test/model_router_test.sh
PASS: 140, FAIL: 0
```

内訳: Unit（parse 22 / gate 12 / has_label 8）+ Integration I1〜I7（86）+ Wiring W1〜W9（12）。
**テスト感度の確認**: 実装へ 4 種の変異（許可値 `case` 検証除去 / gate の loose 比較化 /
既存 `size:*` 判定の無視 / `--add-label` の `--` 打ち切り除去）を注入し、それぞれ
6 / 21 / 8 / 3 件の FAIL が発火することを確認したうえでモジュールを復元した（byte 一致を diff で確認）。

### `bash -n`（新規 module + 変更した既存スクリプト）

`model-router.sh` / `slot-worker.sh` / `watcher-config.sh` / `issue-watcher.sh` /
`idd-claude-labels.sh`（2 系統）/ `model_router_test.sh` の 7 件すべて OK。

### labels script parity（Req 8.5 / whole-file diff は使わない）

`size:` エントリ行の抽出比較で `diff` 出力なし・rc=0。両系統とも追加 3 行 / 削除 0 行
（`git diff --numstat` = `3 0`）。description は 44 / 44 / 50 文字（100 文字以内）。

### Triage prompt の JSON 例

```
$ awk '/^```json$/{f=1;next} /^```$/{if(f)exit} f' local-watcher/bin/triage-prompt.tmpl \
    | sed -e 's/"ready" | "needs-decisions"/"ready"/' -e 's/true | false/true/' \
          -e 's/"safe" | "human-only"/"safe"/' -e 's/"small" | "medium" | "large"/"medium"/' | jq . >/dev/null
jq parse OK
```

### 既存テストの非破壊確認

`local-watcher/test/*_test.sh` 全 99 本を実行し **成功 99 / 失敗 0**。特に本変更が触れる
`module_loader_missing_test`(7) / `sr_wiring_test`(61) / `normalize_slug_test`(12) /
`slug_match_guard_test`(13) / `stage_checkpoint_resumable_state_test`(18) /
`po_apply_awaiting_slot_test`(19) / `po_sticky_comment_helpers_test`(10) を個別に再確認済み。

> **既知の flaky テスト（本 Issue とは無関係 / 確認事項 3 参照）**:
> `publish_terminal_failure_artifacts_test.sh` が Case 5 で間欠的に exit=141（SIGPIPE）で
> 中断する。**分岐元コミット `06c93df`（本変更を含まない）でも 6 回中 3 回再現**したため
> 既存の flakiness と判断した（本ブランチでも 3 回中 2 回は exit=0 / PASS 29, FAIL 0）。

## 手動スモーク手順の記録（tasks.md 7 / Req 8.6）

実物の `model-router.sh` を source し、`gh` を PATH レベルで stub して実行した（ロガーも実物）。

| ケース | 条件 | 結果 |
|---|---|---|
| A | gate 有効 + `size:*` **未作成** repo（`gh issue edit` 失敗） | rc=5 / **WARN 1 行** / 処理継続。gh 2 回（view + edit） |
| B | gate 未設定 | rc=1 / **ログ 0 行 / gh 0 回**（導入前と完全同一） |
| C | gate 有効 + ラベル作成済み | rc=0 / 付与ログ 1 行 / gh 2 回 |
| D | gate 有効 + 既存 `size:large` あり | rc=3 / skip ログ 1 行 / gh 1 回（付与しない） |

実出力（A / B / C の抜粋。ケース A が Req 8.6 の「付与失敗 → WARN → 継続」に対応）:

```
# A
[2026-07-22 17:48:51] [owner/smoke-repo] model-router: WARN: issue=#4242 size ラベルの付与に失敗しました label=size:medium（対象ラベル未定義の可能性: idd-claude-labels.sh の再実行を検討 / 処理は継続）
GH-CALL: issue view 4242 --repo owner/smoke-repo --json labels
GH-CALL: issue edit 4242 --repo owner/smoke-repo --add-label -- size:medium
# B
--> rc=1（1=gate 無効） / gh 呼び出し件数: 0 件
# C
[2026-07-22 17:48:51] [owner/smoke-repo] model-router: issue=#4242 size ラベルを付与しました complexity=medium label=size:medium
```

**未実施**: 実 GitHub repo に auto-dev Issue を立てる E2E（dogfooding）。cron 実行を伴い本
ステージの権限外のため、gh stub による同等条件の shell-level スモークで代替した。

## AC トレーサビリティ

| Requirement | 担保 |
|---|---|
| 1.1〜1.8, 2.1, 2.2, 3.5 | `triage-prompt.tmpl`（JSON 例 2 keys + 判定基準節 / LLM 側指示のため機械テスト対象外。JSON 例の妥当性を `jq` で検証、既存 6 keys 行の差分 0 を `git diff` で検証） |
| 2.3, 2.4 | Unit 2 / Unit 4（key 欠落・null・非文字列・不正 JSON・ファイル不在 → 空文字）、I2 |
| 2.5 | Wiring W8（call site が `$STATUS` / `$NEEDS_ARCHITECT` / `$MODE` を読み書きしない）, W5 |
| 3.1, 3.2, 3.3 | Unit 5（`true` のみ rc=0 / 未設定・空・`false`・`off`・`True`・`TRUE`・`1`・`0`・typo は rc=1）, W2, W3 |
| 3.4 | I5（gh 0 回 / ログ 0 行 / rc=1）, W6 |
| 3.6 | W4（`MODEL_ROUTING_ENABLED` 以外の Phase 別 gate 不在） |
| 4.1 | I1（許可値 3 種の付与 / `--add-label -- size:X` / rc=0） |
| 4.2, 4.3, 4.4 | I4（既存 `size:large` / 人間 override の `size:small` いずれも rc=3・add-label 0 回）, Unit 6 |
| 4.5, 4.6 | W7（gate ブロックが `skip-triage` / `HAS_EXISTING_SPEC` 分岐より後 = else 枝の内側）, W5 |
| 4.7 | I4（skip 理由を含むログを検証） |
| 5.1 | I2, Unit 2 |
| 5.2 | Unit 3, I3（許可値外 / 大文字 / 前後空白 / 注入狙い 3 種で gh 0 回） |
| 5.3 | I6（add-label 失敗 → rc=5 + WARN 1 行）, スモーク A |
| 5.4 | I6（labels 取得失敗 / JSON 解析不能 → rc=4 + add-label 0 回）, Unit 6 |
| 5.5 | 「実行行に `--remove-label` が無い」アサーション（構造的保証） |
| 5.6 | I2 / I3 / I6 の「WARN 1 行」アサーション群 |
| 6.1〜6.5, 7.1, 7.2 | labels script 2 系統の追加 3 行 + parity 抽出比較 + `git diff --numstat`（3 追加 / 0 削除）+ description 文字数計測 |
| 7.3〜7.7 | README（ツリー / opt-in 表 / 新規節）+ CLAUDE.md prefix 表。env var 名・ラベル名・module 名を実装と `grep` で突き合わせ |
| 8.1, 8.2 | shellcheck 警告ゼロ / `bash -n` 7 件 OK |
| 8.3, 8.4 | `model_router_test.sh`（既存命名規約 / 5 ケースを I1〜I5 で網羅） |
| 8.5 | parity 抽出比較（rc=0） |
| 8.6 | 手動スモーク A（上記記録） |
| NFR 1.1 | I5（ログ 0 行 / gh 0 回）, スモーク B |
| NFR 1.2, 1.3 | 既存 env var / ラベル名 / cron 文字列 / ログ出力先を変更していないこと（追加は新規 env 1 件・新規ラベル 3 件のみ）、既存テスト 99 本 PASS |
| NFR 2.1, 2.2 | I1（ログに Issue 番号 + complexity）, I2 / I6（WARN に Issue 番号 / ラベル名） |
| NFR 2.3 | call site が既存 `po_log` と同じ slot stdout に出力（W5 の配置で構造的に担保） |
| NFR 3.1, 3.2 | I7（正常経路 gh 計 2 回）, I5（gate 無効時 0 回） |
| NFR 3.3, 3.4 | Triage prompt の追加が指示文のみで tool 実行経路を増やさないこと（`triage-prompt.tmpl` の差分で確認 / 追加 LLM 起動なし） |
| NFR 4.1, 4.2 | Unit 3 / I3（注入狙い文字列を弾く）, I1（`--add-label -- ` の `--` 打ち切りを検証）, `jq --arg` 使用 |
| NFR 4.3 | `complexity_reason` は module 内に一切出現しない（ラベル名・コマンド引数の構成に不使用） |

## 確認事項（レビュワー判断ポイント）

1. **Req 1.x（Triage の判定精度）は LLM 側の挙動であり機械テストで担保していない**。
   テンプレートに判定基準・固定ルール（`needs_architect: true` → `large` / 境界は大きい側）を
   明記するに留めた。実運用での判定妥当性は dogfooding での観測が必要。
2. **#54 由来の repo-template labels script ドリフトは未是正**（design.md 確認事項 3 と同じ）。
   repo-template 側は旧エントリ 11 件に `【Issue 用】` prefix が無く、root にのみ存在する
   コメント 4 行もある。本 Issue は additive parity に限定したため差分は残る。**別 Issue を
   起票して #54 を repo-template へ反映することを推奨**（起票自体は本 Issue の作業外）。
3. **`publish_terminal_failure_artifacts_test.sh` の間欠 SIGPIPE（exit=141）は本 Issue 以前から
   存在する flaky テスト**（分岐元 `06c93df` で 6 回中 3 回再現）。本 Issue の変更とは無関係
   だが、CI / stage-a-verify を不安定にしうるため別 Issue での調査を推奨する。
4. **ラベル命名 `size:` コロン namespace は requirements の暫定採用のまま**（repo 内にコロン
   namespace の先例なし / requirements の Open Questions）。`size-small` 系へ変える場合の
   変更点は labels script 2 系統と `model-router.sh` 内の literal 2 箇所のみ。
5. **手動 E2E（実 repo で auto-dev Issue を流す dogfooding）は未実施**。gh stub による
   shell-level スモークで代替した（上記「未実施」参照）。merge 後に
   `install.sh --local` の再実行が必要な点は README の新規節に明記済み。

STATUS: complete
