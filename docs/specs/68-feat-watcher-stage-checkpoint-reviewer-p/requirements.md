# Requirements Document

## Introduction

idd-claude の watcher は impl 系モード（`impl` / `impl-resume`）で 3 Stage 構成の
パイプライン（Stage A: PM + Developer / Stage B: Reviewer / Stage C: PjM）を実行する。
現状はどの Stage で失敗しても次の watcher tick で常に Stage A からやり直すため、
Stage B（Reviewer 異常終了等）や Stage C（PjM の PR 作成失敗等）で落ちただけでも
Developer の再実装が走り、token を浪費する。本機能は **Stage 単位の checkpoint** を
導入し、失敗した Stage 以降のみを再実行できるようにする。後方互換性を維持するため
`STAGE_CHECKPOINT_ENABLED` で opt-in する。

## Requirements

### Requirement 1: Stage 完了 checkpoint の確立

**Objective:** As a watcher 運用者, I want 各 Stage の完了が観測可能な形で永続化されること, so that 次回 tick での再開地点を機械的に判定できる

#### Acceptance Criteria

1. When Stage A が成功裏に完了した時, the Watcher Pipeline shall Stage A 完了を示す checkpoint（成果物 `impl-notes.md` の存在）を当該 Issue 用 spec ディレクトリ内に永続化する
2. When Stage B（Reviewer）が approve または reject の判定を出した時, the Watcher Pipeline shall Stage B 完了を示す checkpoint（成果物 `review-notes.md` の存在、最終行 `RESULT: approve|reject`）を当該 Issue 用 spec ディレクトリ内に永続化する
3. When Stage C（PjM）が PR 作成に成功した時, the Watcher Pipeline shall Stage C 完了を当該 Issue 用 PR の存在として観測可能にする
4. The Watcher Pipeline shall checkpoint を当該 Issue ブランチに commit / push して、次回 tick で別 worktree / 別 host から観測可能にする
5. If Stage A / B / C のいずれかが非 0 で異常終了した時, the Watcher Pipeline shall その Stage の checkpoint を完了状態として記録しない

### Requirement 2: 再開地点の判定（impl-resume 起動時）

**Objective:** As a watcher 運用者, I want 失敗した Stage 以降のみを再実行できること, so that 完了済み Stage の再計算で token を浪費せずに済む

#### Acceptance Criteria

1. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when watcher が `impl-resume` モードで起動した場合, the Watcher Pipeline shall checkpoint の有無を確認して再開地点（Stage A / Stage B / Stage C のいずれか）を判定する
2. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when Stage A の checkpoint が存在せず、かつ Stage B / C の checkpoint も存在しない場合, the Watcher Pipeline shall Stage A から実行する
3. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when Stage A の checkpoint が存在し Stage B の checkpoint が存在しない場合, the Watcher Pipeline shall Stage A をスキップして Stage B から実行する
4. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when Stage A と Stage B の checkpoint がともに存在し、かつ Stage B の最終結果が `approve` であって Stage C の完了（PR）が未確認の場合, the Watcher Pipeline shall Stage A / Stage B をスキップして Stage C から実行する
5. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when Stage B の checkpoint が `RESULT: reject` で round=2 完了状態である場合, the Watcher Pipeline shall その Issue を `claude-failed` として人間に委ね、自動再開しない
6. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when 既存の impl PR が同 Issue について既に open / merged 状態で存在する場合, the Watcher Pipeline shall Stage C を再実行せず、その Issue の自動進行を停止する
7. The Watcher Pipeline shall 判定した再開地点と、その判定根拠（どの checkpoint を観測したか）を watcher ログに 1 行以上で記録する

### Requirement 3: opt-in 切替と後方互換性

**Objective:** As a既存の watcher 運用者, I want 既存挙動を壊さずに段階導入できること, so that 既稼働の cron / launchd を移行リスクなしで継続運用できる

#### Acceptance Criteria

1. The Watcher Pipeline shall `STAGE_CHECKPOINT_ENABLED` 環境変数の既定値を `false` とする
2. While `STAGE_CHECKPOINT_ENABLED` が未設定または `false` であるとき, the Watcher Pipeline shall checkpoint 判定を行わず、本機能導入前と完全に同一の Stage A 起点パイプラインで動作する
3. While `STAGE_CHECKPOINT_ENABLED` が `true` 以外の値（空文字 / `0` / `False` / typo 等）であるとき, the Watcher Pipeline shall opt-out として解釈し、Stage A 起点パイプラインで動作する
4. The Watcher Pipeline shall 既存の env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `PR_ITERATION_ENABLED` 等）の意味・既定値を変更しない
5. The Watcher Pipeline shall 既存のラベル名（`claude-claimed` / `claude-picked-up` / `claude-failed` / `awaiting-design-review` / `needs-iteration` / `needs-decisions` 等）の意味・遷移契約を変更しない
6. The Watcher Pipeline shall 既存の cron / launchd 起動文字列を変更せずに新機能を有効化できる（env var 1 個の追加で済む）

### Requirement 4: checkpoint の信頼性と新鮮度判定

**Objective:** As a watcher 運用者, I want stale な checkpoint を誤って採用しないこと, so that 過去 Issue の残骸や手動編集で誤った Stage スキップが発生しない

#### Acceptance Criteria

1. The Watcher Pipeline shall 当該 Issue ブランチの commit 履歴に基づいて checkpoint の新鮮度を判定する（任意の絶対時刻ではなく、現在処理中の Issue ブランチ上の commit が当該 checkpoint を含むかで判断する）
2. If 当該 Issue ブランチに checkpoint ファイルが存在するが、最新 commit の時点でその checkpoint が当該 Issue 番号と紐付いていない場合, the Watcher Pipeline shall その checkpoint を不採用として Stage A から再実行する
3. If `STAGE_CHECKPOINT_ENABLED=true` で起動したものの、checkpoint の解釈に必要な情報（例: `review-notes.md` の `RESULT` 行）が欠落している場合, the Watcher Pipeline shall その Stage を未完了とみなして該当 Stage から再実行する
4. The Watcher Pipeline shall main ブランチに既に merge 済みの過去 spec ディレクトリを、現在処理中の Issue の checkpoint として誤採用しない

### Requirement 5: 失敗・異常系の取り扱い

**Objective:** As a watcher 運用者, I want 想定外の checkpoint 状態でも安全側に倒すこと, so that 部分実行で生成された不整合な成果物が後続実行を破壊しない

#### Acceptance Criteria

1. If Stage 再開判定中に checkpoint ファイル間で状態が矛盾する場合（例: `review-notes.md` が存在するが `impl-notes.md` が無い）, the Watcher Pipeline shall その Issue を Stage A から再実行する
2. If Stage 再開後に再度同じ Stage が失敗した場合, the Watcher Pipeline shall 既存の `claude-failed` 付与契約に従い人間に委ねる
3. The Watcher Pipeline shall checkpoint 判定の失敗（ファイル read エラー等）を silent fail させず、ログに ERROR 行で記録する
4. If `STAGE_CHECKPOINT_ENABLED=true` の下で再開判定が異常終了した場合, the Watcher Pipeline shall 安全側に倒して Stage A から再実行する（部分実行を許さない）

### Requirement 6: ドキュメント整合性

**Objective:** As a watcher 運用者 / consumer repo 利用者, I want 新 env var の存在と挙動が文書化されていること, so that opt-in タイミングや trade-off を理解した上で導入判断できる

#### Acceptance Criteria

1. The README shall `STAGE_CHECKPOINT_ENABLED` を opt-in 環境変数の一覧に追加し、既定値・有効化方法・期待される効果を記載する
2. The README shall 新たに `Stage Checkpoint` セクションを追加し、Stage A / B / C と checkpoint の対応関係、再開判定ロジックの概要、無効化時の挙動を記載する
3. Where opt-in 採用時に挙動が既定と異なる場合, the README shall 影響範囲（既存 cron 起動文字列との互換性、Stage 失敗時の再実行範囲）を明示する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Watcher Pipeline shall `STAGE_CHECKPOINT_ENABLED` 未設定時に本機能導入前と外形的に同一の挙動（同じログ行・同じラベル遷移・同じ exit code 意味）を維持する
2. The Watcher Pipeline shall `repo-template/**` に新たな破壊的変更を加えず、既 install 済み consumer repo に対し `install.sh` 再実行で問題なく上書きできる

### NFR 2: 観測性

1. The Watcher Pipeline shall 各 tick で「checkpoint 判定の入力（spec ディレクトリの存在 / `impl-notes.md` の有無 / `review-notes.md` の最終 RESULT 行 / 既存 PR の有無）」と「判定結果（再開する Stage 名）」をログ 1 ブロック内に出力する
2. The Watcher Pipeline shall checkpoint 採否を切り替えた tick を grep で機械抽出できる識別子付きログ行を出力する（例: `stage-checkpoint:` などの prefix）

### NFR 3: token 効率（本機能の主目的）

1. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when Stage B 単独失敗で再開した場合, the Watcher Pipeline shall Stage A の Developer claude 呼び出しを 0 回に抑える
2. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when Stage C 単独失敗で再開した場合, the Watcher Pipeline shall Stage A / Stage B の claude 呼び出しを 0 回に抑える

### NFR 4: 静的解析

1. The Watcher Pipeline shall 本機能の追加実装後も `shellcheck local-watcher/bin/issue-watcher.sh` を警告ゼロでクリアする

## Out of Scope

- Stage A 内部（PM 実行と Developer 実行の分割 checkpoint 化）。Stage A 内部は単一 checkpoint（`impl-notes.md` 完了 / 未完了）で扱う
- Stage A' / Stage B (round=2) の中間状態の checkpoint 化（Reviewer reject round=1 後の Developer 再実行は既存挙動どおり同一 tick 内で完結させる）
- design ルート（Architect 起動を伴うルート）の checkpoint 化。本機能は impl / impl-resume 系のみを対象とする
- checkpoint の暗号学的署名や改竄検知（運用上の手動編集を許す前提）
- Triage 結果の checkpoint 化（Triage は別段階）
- PR Iteration Processor（`PR_ITERATION_ENABLED`）との連動制御。両者は独立した opt-in として扱う
- LaunchDarkly / Unleash 等の外部 Feature Flag SaaS 連携

## Open Questions

以下は **設計論点として Architect に委任する**（要件レベルでは決定しない）:

1. checkpoint ファイルの新鮮度検知の具体手段（mtime / commit 時刻 / hash / Issue 番号文字列照合 のどれを採用するか） — Req 4.1, 4.2 を満たす方式選定
2. Reviewer reject round=1 後の中断（Stage A' 直前で watcher が落ちた等）からの resume 判定をどう正規化するか — Req 5.1 の「矛盾検出 → Stage A 再実行」で吸収するか、より細かい判定を入れるか
3. #65 で提案・実装される既存 impl PR detection 機構との統合方針（Stage C スキップ条件の重複を避けるための単一の真実の源） — Req 2.6 の責務をどちらが持つか
4. spec ディレクトリが main にも存在する状況下で、当該 Issue ブランチ上に未 commit / 未 push の checkpoint がある場合の取扱い — Req 4.4 の境界処理

これらは Architect が `design.md` で具体的な検証手段を決定する。
