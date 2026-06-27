# Requirements Document

## Introduction

`FAILED_RECOVERY` Processor（#359）は `claude-failed` Issue / auto-merge 待ち PR を fresh Claude
session で復旧する仕組みだが、altpocket-server #119（2026-06-26 JST）で **claude セッションが
約 2 秒で rc=1 で即時失敗するケース** が観測された。現状の実装は試行開始時に attempt カウンタを
加算しており、決定論的に即死する状況では既定 4 attempts を 8 分で空消費して `claude-failed` を
premature に確定させる。さらに dispatch 経路で `LOG` が未設定のため claude の stdout/stderr が
`/dev/null` に捨てられ、即時失敗の真因（cwd / branch checkout 不在の疑い）が事後診断できない。
本要件はこれらを「即時失敗の attempt 除外」「discoverable な専用ログ保存」「対象 repo の作業
ツリーでの起動保証」「起動不能上限による独立エスカレーション」の 4 系統で解消し、quota 燃焼上界
保証（無限リトライ防止）は壊さずに recovery の実効性と診断可能性を回復する。

関連: #410（同インシデントで併発した impl-resume の fixture 追従盲点）と本 Issue は altpocket-server
#119 stuck の二段構成。本要件は recovery 側のみを対象とする。

## Requirements

### Requirement 1: 即時失敗の attempt budget 除外

**Objective:** As an idd-claude 運用者, I want claude が実質作業前に即時失敗した試行を attempt budget から除外できる, so that 決定論的に即死する状況で budget を空消費して `claude-failed` を premature 終端させずに済む

#### Acceptance Criteria

1. If recovery claude session が「実質作業前の即時失敗」と判定された場合, the Failed Recovery Processor shall 当該試行を通算 attempt budget としてカウントしない（カウンタを巻き戻す、または増分自体を保留する）
2. The Failed Recovery Processor shall 「実質作業前の即時失敗」を、claude exit code が非ゼロ（quota sentinel 99 を除く）かつ stream-json 中に tool use イベントが 1 件も観測されず、かつセッション継続時間が即時失敗閾値未満であった場合と定義する
3. The Failed Recovery Processor shall 即時失敗の継続時間閾値を環境変数で上書き可能にし、既定値は安全側（無限リトライにならない側）に倒した正の秒数とする
4. While 同一 Issue / PR に対する即時失敗が連続している間, the Failed Recovery Processor shall 即時失敗連続回数を別カウンタとして state に永続化する
5. If 同一 Issue / PR の即時失敗連続回数が独立上限に到達した場合, the Failed Recovery Processor shall 当該 Issue / PR の処理を停止し、`claude-failed` ラベルを据え置いた上で運用者に手動レビューを促す（Requirement 4 のエスカレーション経路に委譲する）
6. The Failed Recovery Processor shall 即時失敗連続回数の独立上限を環境変数で上書き可能にし、既定値を有限の正の整数値とする（quota 燃焼上界保証として無限リトライを防止する）
7. When recovery claude session が tool use イベントを 1 件以上観測した、または即時失敗閾値以上の時間継続した場合, the Failed Recovery Processor shall 当該試行を「実質作業に着手した試行」として通算 attempt budget に加算し、即時失敗連続回数カウンタをリセットする
8. When recovery claude session が quota 検出 sentinel（exit code 99）で終了した場合, the Failed Recovery Processor shall 既存挙動を維持し、本要件の即時失敗判定経路を適用しない

### Requirement 2: recovery claude 出力の discoverable な専用ログ保存

**Objective:** As an idd-claude 運用者, I want recovery claude セッションの stdout/stderr を専用ログファイルに保存してほしい, so that 即時失敗の事後診断（rc=1 の真因切り分け）が cron.log だけに頼らずに行える

#### Acceptance Criteria

1. When Failed Recovery Processor が recovery claude session を起動する, the Failed Recovery Processor shall 当該セッションの stdout と stderr を専用ログファイルに必ず保存する
2. The Failed Recovery Processor shall 専用ログファイルを `$LOG_DIR` 配下に配置し、ファイル名に kind（`issue` / `pr`）と対象番号とタイムスタンプを含める
3. The Failed Recovery Processor shall 専用ログファイルのファイル名に識別語 `failed-recovery` を含め、運用者が他プロセッサのログと文字列マッチで区別できる命名規約に従う
4. If 呼出側コンテキストで `LOG` 環境変数が未設定であった場合, the Failed Recovery Processor shall 専用ログファイルへの保存を `/dev/null` 行きにフォールバックさせず、Requirement 2.1〜2.3 を満たす保存先を自前で確定する
5. The Failed Recovery Processor shall 専用ログファイル名と保存先を一次運用ログ（cron.log に転送される `failed-recovery:` prefix 付きの行）にも記録し、運用者が該当ログを辿れる導線を残す
6. If 専用ログファイルの作成・書き込みに失敗した場合, the Failed Recovery Processor shall 警告ログを残しつつ recovery 試行自体は継続する（fail-continue / 後方互換）

### Requirement 3: 対象 repo の作業ツリーでの起動保証

**Objective:** As an idd-claude 運用者, I want recovery claude を対象 repo の作業ツリー上で起動してほしい, so that ファイル編集や git 操作が対象 repo に対して効くようになり、rc=1 即時死の真因の主要候補（cwd / branch checkout 不在）を排除できる

#### Acceptance Criteria

1. When Failed Recovery Processor が recovery claude session を起動する, the Failed Recovery Processor shall 対象 repo の作業ツリーがチェックアウトされた状態でセッションを開始する
2. When kind が `pr` の場合, the Failed Recovery Processor shall PR の head branch をチェックアウトした作業ツリーで recovery claude を起動する
3. When kind が `issue` の場合, the Failed Recovery Processor shall 対象 Issue に紐づく既存 claude branch が存在すればそれを、存在しなければ base branch を、チェックアウトした作業ツリーで recovery claude を起動する
4. If 作業ツリーの確保・チェックアウトに失敗した場合, the Failed Recovery Processor shall 警告ログで原因を残した上で当該試行を「実質作業前の即時失敗」と同等に扱い、Requirement 1.1 に従って attempt budget から除外する
5. The Failed Recovery Processor shall 作業ツリーの起点パスを既存の `REPO_DIR` 環境変数で取得し、impl 系プロセッサが使用する作業ツリーと同一の起点を採用する
6. The Failed Recovery Processor shall 作業ツリー上で recovery claude を起動した事実（起点パスと checkout した参照名）を専用ログまたは一次運用ログに記録する

### Requirement 4: 起動不能の独立エスカレーションと区別可能なログ

**Objective:** As an idd-claude 運用者, I want 「max-attempts 到達」と「起動不能（即時失敗連続）」を別の終端理由として区別したい, so that 手動レビュー時に「claude が試行した結果ダメだった」と「claude が動かなかった」を即座に切り分けられる

#### Acceptance Criteria

1. When Requirement 1.5 の独立上限に到達して終端する場合, the Failed Recovery Processor shall 終端理由として `max-attempts` とは異なる識別子（例: `immediate-failure-streak`）を用いる
2. The Failed Recovery Processor shall 当該終端理由を一次運用ログの終端行（`failed-recovery: ... terminated reason=<id>`）に含め、運用者が `grep` で抽出可能にする
3. When Requirement 4.1 の終端が発火した場合, the Failed Recovery Processor shall Issue / PR に終端理由コメントを 1 件だけ投稿し、本文に終端理由識別子と連続即時失敗回数を含める
4. When Requirement 4.1 の終端が発火した場合, the Failed Recovery Processor shall `claude-failed` ラベルを据え置き、手動レビューを促す
5. When Requirement 4.1 の終端が発火した場合, the Failed Recovery Processor shall run-summary の最終結果を `claude-failed` として 1 度だけ確定させ、既存 `max-attempts` / `no-progress` 終端と同じく多重発火を起こさない
6. Where Slack 通知連携が opt-in で有効化されている, the Failed Recovery Processor shall 本終端理由の通知 detail に kind と連続即時失敗回数を含め、failure signature 等の機微値は含めない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Failed Recovery Processor shall 既存の環境変数名（`FAILED_RECOVERY_ENABLED` / `FAILED_RECOVERY_MAX_ATTEMPTS` / `FAILED_RECOVERY_MAX_TURNS` / `FAILED_RECOVERY_DEV_MODEL` / `FAILED_RECOVERY_GIT_TIMEOUT` / `FAILED_RECOVERY_MAX_PRS` / `FAILED_RECOVERY_STATE_DIR` / `LOG_DIR` / `REPO_DIR`）の意味と既定値を維持する
2. The Failed Recovery Processor shall 新たに導入する閾値（即時失敗の継続時間閾値、即時失敗連続上限）を新しい環境変数として追加し、未設定時は安全側（過剰除外で無限リトライにならない側）の既定値を採る
3. The Failed Recovery Processor shall 既存の終端理由識別子（`max-attempts` / `no-progress`）と区別可能な新しい識別子を追加し、既存識別子の文字列は変更しない
4. The Failed Recovery Processor shall 既存の二重 opt-in gate（`FAILED_RECOVERY_ENABLED` AND `FULL_AUTO_ENABLED`）を維持し、本変更で起動条件を緩めない

### NFR 2: 可観測性

1. The Failed Recovery Processor shall 「実質作業前の即時失敗」と判定した試行ごとに、判定根拠（exit code / tool use 観測有無 / 経過秒数）と現在の即時失敗連続回数を一次運用ログ（`failed-recovery:` prefix 付きの行）に記録する
2. The Failed Recovery Processor shall 専用ログファイル名・保存先・recovery claude 起動時の作業ツリー起点パス・checkout した参照名を、運用者が cron.log から該当ログを辿れる粒度で一次運用ログに出力する

### NFR 3: セキュリティ

1. The Failed Recovery Processor shall 専用ログファイル名に含める kind / number / timestamp について、既存の入力検証規約（kind は `issue` / `pr` のみ、number は `^[0-9]+$`、timestamp は ASCII の安全文字のみ）を維持する
2. The Failed Recovery Processor shall 終端理由コメント本文・Slack 通知 detail に GH_TOKEN 等の secrets / failure signature の全文を含めない

## Out of Scope

- claude セッションが rc=1 になる **真因そのものの特定**（CLI バグ・OS 環境差・依存ツール不在等）は本要件の対象外。Requirement 3 で作業ツリーを保証することで「最有力候補」を排除するに留め、それでも再発する場合は別途 Issue で追跡する
- `impl` / `impl-resume` プロセッサ側の `LOG` 設定経路の見直しは本要件の対象外。failed-recovery dispatch 経路のみで `LOG` 未設定問題を自前解決する
- #410（fixture 追従盲点）の修正は別 Issue。altpocket-server #119 の再現ログは検証材料として用いるが、本要件で fixture 側を扱わない
- quota 系の即時失敗（weekly-limit を 529 と誤分類する系統）の網羅性点検は別 Issue（quota-aware の責務）
- recovery claude のプロンプト改善・修正方針改善は本要件の対象外
- 既存の no-progress / max-attempts 判定ロジック自体の変更は本要件の対象外（即時失敗判定は両者の前段に位置付ける）

## Open Questions

- なし（即時失敗の判定基準は Requirement 1.2 / 1.3 / 1.6 で「閾値は env で上書き可能・既定は安全側」として、具体値は Architect / Developer 側の調整事項に委ねる）

## 関連

- Depends on: なし
- Parent: #359
- Related: #410 #119
