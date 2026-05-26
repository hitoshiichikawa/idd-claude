<!-- SPDX-License-Identifier: MIT -->

# 実装ノート: #230 design-less impl における stage-a-verify gate SKIP の明文化

## 概要

本件は新規ロジック実装より **ドキュメント / ポリシーの明文化と escape hatch 後始末手順の整理**が
主体である。design-less impl（tasks.md 不在）で stage-a-verify gate が verify コマンドを推測せず
SKIP する現状挙動を「意図された仕様」として確定し、不採用とした代替案の決定理由を記録し、暫定
escape hatch `STAGE_A_VERIFY_COMMAND` の撤去前提と手順を明文化した。

オーケストレータ確定事項に従い、**Req 1〜4 と NFR 1〜4 を実装対象とし、Req 5（Reviewer regression
backstop）は本 PR では見送り**とした（理由は末尾「Req 5 の見送り」節を参照）。`.claude/agents/reviewer.md`
および Reviewer の判定ルールは変更していない。

## 変更ファイル一覧

| ファイル | 変更種別 | 内容 |
|---|---|---|
| `README.md` | 追記 | 「Stage A Verify Gate (#125)」節に 3 つの新節を追加（design-less SKIP の意図 / 不採用代替案の決定記録 / escape hatch 後始末手順） |
| `.claude/rules/tasks-generation.md` | 追記（最小） | 「verify 対象が無い spec はブロックを省略できる」節に design-less impl が意図された SKIP 仕様である旨の補足 1 段落（README へ相互参照） |
| `.claude/rules/design-review-gate.md` | 追記（最小） | 「verify 対象あり + ブロック/env 両無の扱い（Req 5.3）」節に design-less SKIP が意図された仕様である旨の note ブロック（README へ相互参照） |
| `local-watcher/bin/modules/stage-a-verify.sh` | コメント補足のみ | `stage_a_verify_resolve_command` ヘッダと `stage_a_verify_run` の Gate 2 コメントに「design-less SKIP は意図された仕様」である旨を追記（**挙動・ログ書式・exit code・env var 名は一切変更なし**） |
| `docs/specs/230-.../test-fixtures/test-design-less-skip.sh` | 新規 | design-less SKIP の回帰スモークテスト |
| `docs/specs/230-.../impl-notes.md` | 新規 | 本ノート |

> **コード挙動変更の有無**: `stage-a-verify.sh` への変更は **コメントのみ**であり、ロジック・
> ログ書式・exit code・環境変数名・round counter 契約は一切変更していない（NFR 1）。design-less
> impl → SKIPPED は #224 マージ済みコードの既存挙動であり、本件はそれを「意図された仕様」として
> ドキュメント・コメントで確定したものである。

## 要件 ID → 変更箇所のトレーサビリティ

| Req ID | 内容 | 担保箇所 |
|---|---|---|
| Req 1.1 | design-less で verify を推測せず SKIP | `stage-a-verify.sh` 既存挙動（resolve 全段が return 1）/ test-design-less-skip.sh ケース 1・2 で `resolve rc=1` を assert |
| Req 1.2 | SKIPPED ログ書式（`SKIPPED reason=...` 3 段 prefix）を 1 行以上出力 | `stage_a_verify_run` Gate 2 既存挙動 / test ケース 4 で `stage-a-verify: SKIPPED reason=no-verify-task-in-tasks-md` を grep assert |
| Req 1.3 | round counter を増やさず失敗扱いにしない | `stage_a_verify_run` Gate 2 は round に触れず return 0 / test ケース 4 で round counter 不変を assert |
| Req 1.4 | SKIP 判定で tasks.md を書き換えない | resolve は tasks.md 参照のみ / test ケース 1〜3 で `tasks.md` 不生成を assert |
| Req 2.1 | design-less が gate 対象外（SKIP）である旨を意図仕様として明記 | README「design-less impl（tasks.md 不在）は gate 対象外（意図された仕様）」節 |
| Req 2.2 | regression 担保は Developer テスト + Reviewer AC 判定 | README「design-less impl の regression 担保」節（既存 Reviewer 挙動の説明であり新ルール追加なし） |
| Req 2.3 | 構造化ブロックを持つ Architect ルートは gate 対象（SKIP の例外）と区別記載 | README「構造化 verify ブロックを持つ Architect ルートは gate 対象（SKIP の例外）」節 |
| Req 3.1 | 代替案 (a) 汎用 repo 標準 verifier 自動判定の不採用と理由 | README「検討の上で不採用とした代替案（決定記録）」節 |
| Req 3.2 | 代替案 (c) PM への verify-AC 必須化の不採用と理由 | 同上 |
| Req 3.3 | 採用方針が「推測しない」設計思想（#224 / #228）と整合する旨 | 同節末尾段落 |
| Req 4.1 | escape hatch 撤去の前提条件（#224 マージ・デプロイ・E2E 完了）を明記 | README「暫定 escape hatch ... の後始末手順」節 |
| Req 4.2 | #224 完了後に cron / launchd から撤去できる | 同節「撤去はリポジトリ外のオペレータ作業」 |
| Req 4.3 | 撤去後は Architect ルートが構造化ブロックで解決 / design-less は SKIP に戻る | 同節「撤去後の挙動」 |
| Req 4.4 | 構造化ブロックが env より優先される旨を明記 | 同節「解決順序における優先度」+ 既存「解決順序（fallback 連鎖）」節 |
| Req 4.5 | env を repo-default として残す運用も選択肢 | 同節「repo-default として残す選択肢」/ test ケース 3 で env 採用（rc=0）を assert |
| NFR 1.1〜1.5 | env var 名 / ログ書式 / exit code / ラベル契約の後方互換 | コード変更はコメントのみ。挙動不変。shellcheck 警告ゼロ |
| NFR 2.1 | #224 完了前は escape hatch を維持 | README 後始末節の前提条件記述 |
| NFR 2.2 | 撤去はローカル設定へのオペレータ作業、repo 側は明文化のみ | README「撤去はリポジトリ外のオペレータ作業」 |
| NFR 4.1 | 同一入力で同一解決結果（SKIP） | test ケース 2（冪等 2 回目）で rc=1 を再確認 |
| NFR 4.2 | 前回サイクルの残値に影響されず常に SKIP | resolve 冒頭で `_SAV_RESOLVED_SOURCE` / source sidecar を初期化する既存挙動 / test ケース 1・2 |

## Test plan（CLAUDE.md「テスト・検証」準拠）

本リポジトリに unit test フレームワークは無いため、静的解析 + スモークで検証した。

### shellcheck（変更ファイル）

- `shellcheck local-watcher/bin/modules/stage-a-verify.sh` → **exit 0（警告ゼロ）**
- `shellcheck docs/specs/230-.../test-fixtures/test-design-less-skip.sh` → **exit 0（警告ゼロ）**
- `shellcheck local-watcher/bin/issue-watcher.sh` は SC2317（info: unreachable command）が 5 件出るが、
  いずれも **本件で変更していない既存箇所**（logger 関数の echo）であり、本件の追加とは無関係。

### design-less SKIP スモークテスト

`bash docs/specs/230-feat-watcher-stage-a-verify-design-less/test-fixtures/test-design-less-skip.sh`
→ **PASS=4 FAIL=0（exit 0）**

- ケース 1: tasks.md 不在 + env 未設定 → `resolve rc=1`（SKIP）
- ケース 2: tasks.md 不在 + env 未設定（冪等 2 回目）→ `resolve rc=1`（NFR 4.1）
- ケース 3: tasks.md 不在 + `STAGE_A_VERIFY_COMMAND=make test` → `resolve rc=0`（env 採用 / Req 4.5）
- ケース 4: `stage_a_verify_run` 統合 → `SKIPPED reason=no-verify-task-in-tasks-md` ログ出力 +
  round counter 不変 + rc=0（Req 1.1 / 1.2 / 1.3）

### 既存回帰テスト

- `bash docs/specs/224-.../test-fixtures/test-extract.sh` → **All 14 cases passed（exit 0）**。
  本件のコメント追記で #224 の構造化ブロック抽出・4 段 fallback 連鎖が壊れていないことを確認。

### markdown 整合

- README 追加節の見出し階層（`## Stage A Verify Gate` 配下に `###` / `####`）が一貫していることを目視確認。
- 各 rule の追記は相互参照（README へのリンク）で二重管理を避けた。
- 重複追記なし（各新節見出し / note ブロックは 1 件ずつ）。

### 冪等性

- 編集はすべて固有文字列への 1 回限りの追記であり、再適用で重複しない。コード挙動は不変のため
  install.sh 再配置による破壊もない。

## 確認事項（レビュワー判断ポイント）

- **escape hatch の実撤去はリポジトリ外作業**: 本 PR は撤去の前提・手順を明文化するのみで、
  実際の cron / launchd 設定からの `STAGE_A_VERIFY_COMMAND` 削除は行っていない（NFR 2.2 / Out of Scope）。
  本件スモークテスト実行中、実行環境（このワーカーの親プロセス）が `STAGE_A_VERIFY_COMMAND` を
  `shellcheck --severity=warning ...` として export している事実を観測した。これは #230 が整理対象と
  する暫定設定そのものであり、テストは env を明示 unset することで design-less SKIP を検証している。
  **#224 のマージ・デプロイ・E2E 確認が完了次第、運用者は cron 側の当該 env を撤去できる**（Req 4.2）。
- rule 側の追記は README を主とし最小限（相互参照）に留めた。二重化を避ける方針が妥当か確認されたい。

## Req 5 の見送り

Req 5（Reviewer regression backstop）はオーケストレータ判断により本 PR では見送り（別 Issue 分離可）。
`.claude/agents/reviewer.md` および Reviewer の判定ルールは変更していない（requirements.md Open
Questions の PM 推奨スタンスおよびオーケストレータ確定事項に従う）。

STATUS: complete
