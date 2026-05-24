# Requirements Document

## Introduction

design フェーズの Issue が open な design PR（`claude/issue-<N>-design-*` head）を持っている状態で、
保護ラベル（`awaiting-design-review` / `blocked`）が何らかの理由で外れると、watcher が当該 Issue を
再 pickup して design モードを再実行し、PjM サブエージェントが既存の人間レビュー済み design PR を
クローズして新規 PR を作り直す事故が発生する（#180 / PR #184 で実観測）。現状の claim 直前ガードは
impl PR の open/merged 状態のみを再 dispatch 抑止の対象とし、design PR は明示的に無視するため、保護が
ラベルのみに依存している。本要件は、Issue pickup 経路に「open な design PR が存在すれば触らない」最後の砦
となるガードを追加し、ラベル保護が外れてもレビュー済み design PR が破壊的に再生成されないことを担保する。

## Requirements

### Requirement 1: open design PR ガードによる再 dispatch 抑止

**Objective:** As a 運用者, I want open な design PR を持つ Issue が再 dispatch されないこと, so that 人間レビュー済みの design PR とレビュー履歴が失われない

#### Acceptance Criteria

1. While 対象 Issue に open 状態の design PR が存在する, when watcher が当該 Issue を claim しようとする, the Issue Watcher shall 当該サイクルでの dispatch を skip する
2. While 対象 Issue が open な design PR を持ち保護ラベル（`awaiting-design-review` / `blocked`）をいずれも持たない, when watcher が当該 Issue を評価する, the Issue Watcher shall design モードの再実行を起動しない
3. When 対象 Issue にリンクされた design PR が CLOSED または MERGED のみで open な design PR が存在しない, the Issue Watcher shall 本ガードによる skip を行わず後続処理へ進む
4. The Issue Watcher shall 対象 Issue 番号に対応する design PR の検出を、当該 PR が Issue に linked であるか否かに依存せず行う
5. The Issue Watcher shall 対象 Issue 番号に厳密に対応する head ブランチの design PR のみを本ガードの対象として扱う（他 Issue 用の design PR を誤検出しない）

### Requirement 2: ラベル保護との二重防御

**Objective:** As a 運用者, I want 既存のラベルベース除外と新ガードが併存すること, so that 一方が機能しなくても他方が再生成を防ぐ

#### Acceptance Criteria

1. While 対象 Issue が保護ラベル（`awaiting-design-review` / `blocked`）を持つ, when watcher が candidate を収集する, the Issue Watcher shall 既存のラベルベース除外挙動を維持する
2. Where open design PR ガードが導入されている, the Issue Watcher shall 保護ラベルが外れた状態の Issue に対しても open design PR 単体で再生成を抑止する

### Requirement 3: 検出失敗時の fail-safe

**Objective:** As a 運用者, I want design PR 検出が失敗したときに安全側へ倒れること, so that 検出系の不調を理由にレビュー済み PR を破壊しない

#### Acceptance Criteria

1. If 対象 Issue の design PR 検出に失敗する, the Issue Watcher shall 当該 Issue の dispatch を skip する
2. If design PR 検出がタイムアウトまたはレート制限により完了しない, the Issue Watcher shall 当該 Issue の dispatch を skip する

### Requirement 4: skip 時の可視性

**Objective:** As a 運用者, I want ガードが作動した理由をログで確認できること, so that 想定外の skip を後から監査できる

#### Acceptance Criteria

1. When 本ガードにより Issue の dispatch を skip する, the Issue Watcher shall skip 理由と検出した design PR 番号を含む 1 行のログを cron ログに記録する
2. The Issue Watcher shall 当該ログ行を、既存 Pre-Claim 系ログと同一の `key=value` 形式（Issue 番号・PR 番号・理由を機械可読に含む）で出力する

### Requirement 5: PR Iteration（design）との非干渉

**Objective:** As a 運用者, I want design PR 反復機能が本ガードの影響を受けないこと, so that レビュー指摘に基づく design PR の更新運用が継続できる

#### Acceptance Criteria

1. Where design PR の反復処理機能が有効である, the Issue Watcher shall PR 駆動（`needs-iteration` ラベル）の design PR 反復を本ガード導入前と同一に継続する
2. The Issue Watcher shall 本ガードを Issue pickup 経路にのみ適用し、PR 駆動の反復処理経路に作用させない

## Non-Functional Requirements

### NFR 1: 後方互換性（通常 Issue の挙動不変）

1. While 対象 Issue が design PR を持たない, the Issue Watcher shall 本機能導入前と同一の dispatch 挙動を維持する
2. The Issue Watcher shall 既存の環境変数名・exit code の意味・ラベル契約・cron 登録文字列・ログ出力先を変更しない
3. The Issue Watcher shall 本ガードに伴う GitHub API 呼び出しを既存のタイムアウト規律（既定 60 秒）の下で実行する

### NFR 2: 運用ガイドの整合

1. The README shall open な design PR を持つ Issue の保護ラベルを当該 design PR が merge されるまで外さない暫定運用ガイドを記載する

## Out of Scope

- watcher 本体に `gh pr close` 等で既存 design PR を直接クローズ／削除する処理を追加すること（クローズは design 再実行中の PjM の判断で起きており、本要件は再実行の起動自体を抑止する）
- impl PR に対する既存の claim 直前ガード（open/merged impl PR での skip）の挙動変更
- 既に発生済みの事故（#180 / PR #184）の事後復旧処理の自動化
- design PR 以外の保護対象（impl PR / 一般 PR）への新規ガード追加
- 保護ラベルが外れる根本原因（運用フロー・他機能のラベル除去）の是正
- design PR 反復機能（`needs-iteration` 駆動）の機能追加・挙動変更
- skip 時に Issue へ sticky comment で通知する機能（Open Questions に判断委譲）

## Open Questions

- skip 時に cron ログ記録に加えて Issue へ sticky comment で通知すべきか（Issue 本文の受入観点 4 で「必要なら判断」とされており、人間の決定回答が未取得）。通知を行う場合の頻度・重複抑止方針も併せて要確認。
