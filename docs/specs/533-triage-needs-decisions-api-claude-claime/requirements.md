# Requirements Document

## Introduction

Triage が needs-decisions を判定した際、決定事項コメントの投稿と `claude-claimed → needs-decisions`
のラベル遷移が失敗を握り潰す形で呼ばれており、GitHub API のレート制限時間帯にはコメント 0 件・
ラベル未遷移・`claude-claimed` 残留のまま「決定事項を起票しました」という成功ログが出力される。
結果として人間への質問が届かず、`claude-claimed` 残留により次サイクルの再 pickup も起きない「宙吊り」
状態になる。本要件は成功ログの不正確さを是正し、needs-decisions 遷移が完了できなかった場合でも
`claude-claimed` を残留させない（質問到達か次サイクル再処理のいずれかを常に保証する）ことを定義する。
レート制限起因失敗の有限回リトライは既存の opt-in gate（`GH_API_STATE_RETRY_ENABLED`、#521）を活用し、
本件は #530（異常時 claim 残留の自動回収）と同系の予防措置に位置づけられる。

## Requirements

### Requirement 1: 決定事項コメント投稿の成否検証と正確なログ

**Objective:** As an idd-claude 運用者, I want 決定事項コメントが実際に投稿できたときだけ成功として記録される, so that レート制限等による投稿失敗を成功と誤認せず、人間への質問喪失に気づける

#### Acceptance Criteria

1. When Triage が needs-decisions を判定し決定事項コメントの投稿が成功したとき, the Slot Worker shall 「決定事項を起票しました」を示す成功ログを出力する
2. If 決定事項コメントの投稿が失敗したとき, the Slot Worker shall 「決定事項を起票しました」を示す成功ログを出力しない
3. If 決定事項コメントの投稿が失敗したとき, the Slot Worker shall 失敗を warn ログで明示する

### Requirement 2: claude-claimed から needs-decisions へのラベル遷移の成否検証と正確なログ

**Objective:** As an idd-claude 運用者, I want ラベル遷移が実際に完了したときだけ成功として記録される, so that ラベル未遷移（claude-claimed 残留）を「取り消し済」と誤って記録しない

#### Acceptance Criteria

1. When `claude-claimed` 除去と `needs-decisions` 付与のラベル遷移が成功したとき, the Slot Worker shall 「claude-claimed 取り消し済」を示す成功ログを出力する
2. If ラベル遷移が失敗したとき, the Slot Worker shall 「claude-claimed 取り消し済」を示す成功ログを出力しない
3. If ラベル遷移が失敗したとき, the Slot Worker shall 失敗を warn ログで明示する

### Requirement 3: 宙吊り防止（claim 残留の禁止・最重要不変条件）

**Objective:** As an idd-claude 運用者, I want needs-decisions 遷移が完了できなかったときに claude-claimed が残留しない状態になる, so that 質問が人間に届くか次サイクルで再処理されるかのいずれかが必ず保証され、Issue が宙吊りにならない

#### Acceptance Criteria

1. The Slot Worker shall 「`claude-claimed` 付与のまま、かつ成功ログを出力し、かつ質問が人間へ未到達」となる状態を発生させない
2. If 決定事項コメントの投稿またはラベル遷移が完了できなかったとき, the Slot Worker shall `claude-claimed` を残留させず、当該 Issue を次サイクルの再 pickup 対象（`auto-dev` 保持・claim 系ラベル非在）へ戻す
3. When `claude-claimed` を除去して次サイクルへ処理を委ねたとき, the Slot Worker shall needs-decisions 遷移が未達だった事実を warn ログで明示する

### Requirement 4: レート制限起因失敗の特別扱いとリトライ／委譲

**Objective:** As an idd-claude 運用者, I want レート制限起因の失敗を有限回リトライまたは次サイクルへ委譲する, so that 一過性のレート枯渇でも最終的に質問が人間へ届く

#### Acceptance Criteria

1. Where レート制限リトライ機能が有効化されている（`GH_API_STATE_RETRY_ENABLED=true`）とき and ラベル遷移がレート制限起因（HTTP 403 / 429 / RATE_LIMITED / too many requests 等の応答）で失敗したとき, the Slot Worker shall 設定された上限まで有限回リトライする
2. If リトライ上限に到達しても needs-decisions 遷移が完了しないとき, the Slot Worker shall `claude-claimed` を残留させず次サイクルへ処理を委ねる
3. If 失敗がレート制限起因でないとき, the Slot Worker shall 不要な追加 API 消費を避けるため、リトライせず失敗として扱う

### Requirement 5: 後方互換と opt-in（成功ログ正確性は gate 非依存で常時成立）

**Objective:** As an idd-claude 運用者, I want 成功ログの正確性と claim 非残留がリトライ gate の有効／無効に依らず常に成立し、既存 gate の既定値が導入前と同じ API 消費・挙動を保つ, so that 新機能を有効化していない環境でも宙吊りが解消され、かつ従来環境の互換性が壊れない

#### Acceptance Criteria

1. The Slot Worker shall 成功ログの正確性（出力が実際の成否と一致すること）を、レート制限リトライ gate の有効／無効に依らず常に保証する
2. The Slot Worker shall claim 非残留の不変条件（Requirement 3）を、レート制限リトライ gate の有効／無効に依らず常に保証する
3. Where レート制限リトライ機能が無効（既定 `GH_API_STATE_RETRY_ENABLED=false`）のとき, the Slot Worker shall 決定事項コメント投稿とラベル遷移をそれぞれ 1 回だけ実行し、追加の API 消費を発生させない
4. If 本要件の実現のために新規 env gate を追加するとき, the 新規 gate shall 既定値を導入前と互換な安全側（失敗検知が有効で宙吊りが起きない側）に設定する

### Requirement 6: 次サイクル再処理時の冪等性

**Objective:** As an idd-claude 運用者, I want claim 解除後の次サイクル再 Triage で同じ needs-decisions を再生成しても label 状態が破綻しない, so that 復旧経路が矛盾状態やゴミを残さず一貫状態へ収束する

#### Acceptance Criteria

1. When 次サイクルで同一 Issue に対し needs-decisions 遷移を再実行したとき, the Slot Worker shall `claude-claimed` と `needs-decisions` が同時に付与された矛盾状態を残さない
2. While ある Issue が `needs-decisions` ラベルを保持しているとき, the Dispatcher shall 当該 Issue を新規 pickup 候補に含めない
3. When needs-decisions 遷移が最終的に完了したとき, the system shall 決定事項コメントが少なくとも 1 件存在し `needs-decisions` ラベルが付与された一貫状態へ収束する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Slot Worker shall 既存の env var 名・ラベル名（`claude-claimed` / `needs-decisions` / `auto-dev`）・exit code の意味・ログ出力先を変更しない
2. While needs-decisions 遷移が成功する通常経路にあるとき, the Slot Worker shall 本要件導入前と同一のログ行・ラベル遷移・戻り値を出力する

### NFR 2: 可観測性

1. The Slot Worker shall 決定事項コメント投稿・ラベル遷移・claim 解除の各失敗について silent fail を作らず、warn ログに失敗事実を残す
2. The warn ログ shall 対象 Issue 番号と失敗した操作種別を含める

## Out of Scope

- レート制限そのものの削減・API 消費最適化（サイクル内 snapshot 共有・バケット縮退等、#521 本体の範囲）
- needs-decisions 分岐以外の状態遷移（impl 着手時のラベル付け替え等）における失敗握り潰しの是正（同種パターンが他所にあれば別 Issue として起票する）
- 決定事項コメントの文面・テンプレートの変更
- Triage の complexity 判定および needs-decisions auto-continue（#362）ロジックの変更
- 既に発生してしまった宙吊り Issue の事後回収の仕組み（#530 / stale-pickup-reaper 側の責務。本 Issue は発生源での予防に限定する）

## Open Questions

- claim を解除して次サイクルへ委ねる復旧経路では、直前サイクルで「決定事項コメント投稿だけ成功し
  ラベル遷移が失敗した」ケースにおいて、次サイクルの再 Triage で決定事項コメントが重複投稿され得る。
  PM 推奨は「重複投稿を許容する（最終的に一貫状態へ収束するため）」だが、コメント冪等化（既存 marker 検出等）
  を要否判断するかは実装者に委ねる。人間からの明示回答は現時点で無し（bot の処理開始コメント 1 件のみ）。

---

## 自己レビュー（requirements-review-gate.md 準拠 / 最大 2 パス）

### パス 1: Mechanical Checks

- Numeric ID: すべての要件見出しが `Requirement 1`〜`6` / `NFR 1`〜`2` の numeric ID。英字 ID なし → OK
- AC の存在: 全 6 要件 + 2 NFR に EARS 形式 AC（When / If / While / Where / The <subject> shall）が 1 件以上 → OK
- 実装語彙の混入: DB 名・フレームワーク名・API パターン・内部関数名・行番号を AC 本文に含めない。
  env var 名（`GH_API_STATE_RETRY_ENABLED`）とラベル名は operator-observable な設定／状態のため許容 → OK

### パス 1: 判断レビュー

- スコープ・カバレッジ: 成功ログの正確性（Req 1, 2）・宙吊り防止の不変条件（Req 3）・レート制限特別扱い
  （Req 4）・後方互換 / opt-in（Req 5）・冪等性（Req 6）を機能要件で網羅。主要エラーケース（投稿失敗・
  ラベル遷移失敗・レート制限・非レート制限失敗）を AC 化 → OK
- EARS・テスト可能性: 各 AC は observable（ログ行の有無・ラベル状態・再 pickup 可否）で検証可能 → OK
- 構造: コメント（Req 1）とラベル遷移（Req 2）を分離し 1 AC = 1 挙動を維持。不変条件は Req 3 に集約 → OK
- 既存整合: 候補 Issue クエリが `needs-decisions` / `claude-claimed` を server-side 除外する既存挙動
  （Req 6.2）と矛盾しないことを確認 → OK

### 判定

Mechanical Checks・判断レビューともに指摘なし。パス 1 で確定（2 パス目不要）。残存曖昧点はコメント重複の
扱いのみで、PM 推奨を添えて Open Questions に記載済み。
