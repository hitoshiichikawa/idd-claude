<!-- SPDX-License-Identifier: MIT -->

# Requirements Document

## Introduction

stage-a-verify gate (#125) は Stage A（Developer 実装）完了直前に `tasks.md` の build/test/lint
コマンドを watcher が独立再実行し、build 不通の Stage A 通過を構造的に防ぐ仕組みである。#224 で
構造化 verify ブロック（センチネル + fence）が input 契約として導入され、コマンド解決順序は
「構造化ブロック → `STAGE_A_VERIFY_COMMAND` env → ヒューリスティック抽出 → SKIPPED」の 4 段
fallback として既に main にマージ済み（commit d34f918）である。一方で、tasks.md を持たない
design-less impl（#204 等）における gate の扱いは、現行コードでは自然に SKIPPED になるものの
「意図された仕様」としては明文化されていない。本件は (1) design-less impl が gate 対象外
（SKIP）であることを意図として明文化し、(2) 不採用とした代替案の決定理由を記録し、(3) 過去の
散文誤認事故（#160 / #219 / #221）への暫定対応として cron 設定へ入れた escape hatch
`STAGE_A_VERIFY_COMMAND` の撤去前提と手順を明示し、(4) 任意で Reviewer による regression
backstop を整理することを目的とする。新規ロジック実装より、方針確定・明文化・後始末の整理が主体である。

## Requirements

### Requirement 1: design-less impl における gate SKIP の明文化

**Objective:** As a watcher operator, I want design-less impl（tasks.md 不在）で stage-a-verify gate が verify コマンドを推測せず SKIP すること, so that 散文をコマンドと誤認する事故を構造的に避けつつ既存の SKIPPED 挙動を意図された仕様として確定できる

#### Acceptance Criteria

1. While design-less impl（tasks.md 不在）かつ gate 有効, the stage-a-verify gate shall verify コマンドを推測せず SKIP する（gate 未適用として Stage A を続行する）
2. When gate が design-less impl で SKIP する, the stage-a-verify gate shall 既存の SKIPPED ログ書式（`SKIPPED reason=<理由>` を含む 3 段 prefix 行）を 1 行以上出力する
3. While design-less impl で gate が SKIP した, the stage-a-verify gate shall round counter を増加させず Issue を失敗扱い（差し戻し / claude-failed）にしない
4. The stage-a-verify gate shall design-less impl の SKIP 判定で `tasks.md` を書き換えない

### Requirement 2: design-less SKIP を意図として記載するドキュメント

**Objective:** As an operator or contributor, I want design-less impl が stage-a-verify の対象外である旨がドキュメントに意図として明記されていること, so that SKIP が「未実装の取りこぼし」ではなく「設計された仕様」であると誤読なく理解できる

#### Acceptance Criteria

1. The documentation shall design-less impl（tasks.md 不在）が stage-a-verify gate の対象外（SKIP）である旨を意図された仕様として明記する
2. The documentation shall design-less impl の regression 担保が Developer が実行するテストと Reviewer の AC 判定によって行われる旨を記載する
3. Where 構造化 verify ブロックを持つ Architect ルートの spec, the documentation shall 当該 spec が gate の対象であり design-less SKIP の例外である旨を区別して記載する

### Requirement 3: 不採用とした代替案の決定記録

**Objective:** As a future contributor, I want 検討の上で不採用とした代替アプローチとその理由が記録されていること, so that 同じ議論の蒸し返しを避け将来の意思決定者が背景を再構築できる

#### Acceptance Criteria

1. The documentation shall 汎用 repo 標準 verifier の自動判定（代替案 a）を採用しない決定とその理由を記録する
2. The documentation shall PM による verify コマンド AC 必須化（代替案 c）を採用しない決定とその理由を記録する
3. The documentation shall 採用方針（Architect ルートは構造化 verify ブロック / design-less は SKIP）が「推測しない」設計思想と整合する旨を記録する

### Requirement 4: 暫定 escape hatch の後始末手順

**Objective:** As a watcher operator, I want 暫定対応として cron 設定へ入れた `STAGE_A_VERIFY_COMMAND` を安全に撤去できる前提と手順が明示されていること, so that #224 デプロイ後に暫定設定を残し続けて将来の挙動を曇らせるのを避けられる

#### Acceptance Criteria

1. The documentation shall 暫定 escape hatch `STAGE_A_VERIFY_COMMAND` を撤去できる前提条件（#224 のマージ・デプロイ・end-to-end 確認の完了）を明記する
2. When #224 がマージ・デプロイ・end-to-end 確認された後, the operator shall cron / launchd 設定から暫定 `STAGE_A_VERIFY_COMMAND` を撤去できる
3. While escape hatch を撤去した状態, the stage-a-verify gate shall Architect ルートの spec を構造化 verify ブロックで解決し design-less impl を SKIP に戻す
4. The documentation shall コマンド解決順序において構造化 verify ブロックが `STAGE_A_VERIFY_COMMAND` env より優先される旨を明記する
5. Where 運用者が design-less impl の repo 共通既定 verify を維持したい場合, the documentation shall `STAGE_A_VERIFY_COMMAND` を任意の repo-default として残す運用が選択肢である旨を記載する

### Requirement 5: （任意）Reviewer regression backstop

**Objective:** As a reviewer, I want design-less impl で AC 対応の既存テストを turn budget 内で再実行し regression を検出できること, so that gate が SKIP される design-less ケースでも build/test 退行を検出する backstop を持てる

#### Acceptance Criteria

1. Where Reviewer backstop を採用する, the reviewer shall design-less impl で AC 対応の既存テストを turn budget 内で再実行する
2. Where Reviewer backstop を採用し、かつ再実行したテストが失敗した, the reviewer shall 既存の `missing test` または `AC 未カバー` カテゴリで reject する
3. Where Reviewer backstop を採用する, the reviewer shall 新しい reject カテゴリを追加せず既存 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）の範囲に判定を限定する
4. Where Reviewer backstop を採用しない, the reviewer shall 既存の 3 カテゴリ判定挙動を変更しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `STAGE_A_VERIFY_ENABLED=false` が明示指定された, the stage-a-verify gate shall 本件導入前と完全に同一の挙動（DISABLED で skip、`stage-a-verify:` ログ行を出さない）を維持する
2. The stage-a-verify gate shall 既存の env var 名（`STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` / `STAGE_A_VERIFY_COMMAND` および `REPO` / `REPO_DIR` / `LOG_DIR` 等）の名前と既定値を変更しない
3. The stage-a-verify gate shall 既存ラベル名と遷移契約（`needs-iteration` を Issue 側に付与しない契約を含む）を変更しない
4. The stage-a-verify gate shall 既存 exit code の意味（成功 0 / 差し戻し / claude-failed の戻り値契約）を変更しない
5. The stage-a-verify gate shall 既存ログ書式（`[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify:` の 3 段 prefix）を変更しない

### NFR 2: escape hatch 撤去のタイミング制約

1. While #224 のマージ・デプロイ・end-to-end 確認が完了していない, the operator shall 暫定 escape hatch `STAGE_A_VERIFY_COMMAND` を維持し現状の挙動を保つ
2. The documentation shall escape hatch 撤去がリポジトリ外のローカル設定（cron / launchd）に対するオペレータ作業であり、リポジトリ側の作業は撤去可否・前提条件・優先順位の明文化に限られる旨を記載する

### NFR 3: Reviewer 判定境界の不変性

1. The reviewer shall reject 可能なカテゴリを AC 未カバー / missing test / boundary 逸脱 の 3 種のみに維持し、本件で新カテゴリを追加しない
2. Where Reviewer backstop を採用する, the reviewer shall backstop による判定を既存 3 カテゴリの錨づきの範囲内に限定する

### NFR 4: 冪等性

1. The stage-a-verify gate shall 同一入力（同一 tasks.md 状態・同一 env）に対し、再実行しても同一の解決結果（SKIP / 実行 / DISABLED）を返す
2. While design-less impl で gate を SKIP する, the stage-a-verify gate shall 前回サイクルの解決手段の残値に影響されず常に SKIP と判定する

## Out of Scope

- コマンド解決順序（構造化ブロック > env > heuristic > SKIPPED）そのものの実装変更（#224 でマージ済み）
- 汎用 repo 標準 verifier の自動判定機能の実装（代替案 a、本件では不採用決定の記録のみ）
- PM による verify コマンド AC 必須化のルール化（代替案 c、本件では不採用決定の記録のみ）
- 構造化 verify ブロックの書式・パース仕様の変更（#224 / `tasks-generation.md` で確定済み）
- escape hatch の実際の撤去作業そのもの（リポジトリ外の cron / launchd 設定変更であり、本件はその前提・手順の明文化のみ）
- 外部 Feature Flag SaaS / 動的フラグ等の導入
- ヒューリスティック抽出のキーワード集合の拡張

## Open Questions

- Requirement 5（Reviewer regression backstop）を本 PR のスコープに含めるか否か。PM 推奨スタンスは「本 PR では design-less SKIP の明文化・不採用決定の記録・escape hatch 後始末手順を確実に固め、Reviewer backstop は任意（採用は別 Issue へ分離可）」とする。本 requirements は Requirement 5 を `Where Reviewer backstop を採用する` の条件付き要件として記述しており、採用・見送りのいずれでも他要件は破綻しない。採否は人間判断にエスカレーションする。
