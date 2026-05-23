# Requirements Document

## Introduction

Quota-Aware Watcher (#66) は quota 超過検知時に reset 予定時刻を Issue body の hidden marker `<!-- idd-claude:quota-reset:<epoch>:v1 -->` として永続化している。この永続化は `qa_persist_reset_time` が Issue body を read（`gh issue view`）→ marker 行を除去・追記 → write（`gh issue edit --body`）する read-modify-write 方式であり、view と edit の間に人間が GitHub UI で同 Issue 本文を編集すると、その編集が watcher の上書きで失われる lost update が起こり得る。quota wait は長時間 Issue で発生しやすく、人間が同じ Issue を編集している確率が高いため実害リスクがある。本変更は reset 予定時刻の永続化先を Issue body から **ローカル watcher 環境内のファイル**（repo slug 単位で分離済みの `LOG_DIR` 配下）へ移し、Issue body への書き込みを廃止することで lost update を根本解消する。移行期に既に `needs-quota-wait` 状態でローカル記録を持たない Issue が存在し得るため、読取側は本文 marker の後方互換読取も維持する。

## Requirements

### Requirement 1: reset 時刻の永続化先をローカルファイルへ移行（lost update の根本解消）

**Objective:** As a 運用者, I want quota reset 予定時刻が Issue body ではなくローカル watcher 環境内に保存されること, so that 人間が GitHub UI で同じ Issue 本文を編集しても watcher の永続化処理が人間の編集を上書きしない

#### Acceptance Criteria

1. When watcher が quota 超過検知時に reset 予定時刻を永続化するとき, the Issue Watcher shall 当該 reset 予定時刻をローカル watcher 環境内のファイルに書き込む
2. When watcher が reset 予定時刻を永続化するとき, the Issue Watcher shall 当該 Issue body に対する書き込み（`gh issue edit --body` 相当の本文上書き）を行わない
3. While reset 予定時刻の永続化処理が走っている間, the Issue Watcher shall Issue body の read-modify-write（取得した本文を編集して全体を上書きする処理）を行わない
4. The Issue Watcher shall reset 予定時刻の永続化先ファイルを repo slug 単位で分離された `LOG_DIR` 配下に配置し、異なる repo の reset 時刻が同一ファイルに混在しない状態を保つ

### Requirement 2: 複数 Issue の reset 時刻を Issue 番号で区別

**Objective:** As a 運用者, I want 同一 repo 内で複数 Issue が同時に quota wait に入っても各 Issue の reset 時刻が区別されること, so that ある Issue の reset 時刻が別 Issue の判定に誤って使われない

#### Acceptance Criteria

1. When 同一 repo の複数 Issue がそれぞれ reset 予定時刻を永続化するとき, the Issue Watcher shall 各 reset 予定時刻を Issue 番号で keying して区別可能な形で保持する
2. When 後続の cron tick で特定 Issue の reset 予定時刻を読み出すとき, the Issue Watcher shall 当該 Issue 番号に対応する reset 予定時刻のみを返す
3. When 同一 Issue について新しい reset 予定時刻を永続化するとき, the Issue Watcher shall 当該 Issue の以前の reset 予定時刻を新しい値で置き換え、1 Issue につき最新値 1 件のみが有効である状態を保つ

### Requirement 3: 読取の後方互換（ローカルファイル優先・本文 marker フォールバック）

**Objective:** As a 移行期の運用者, I want 本変更デプロイ前に既に `needs-quota-wait` 状態でローカル記録を持たない Issue でも自動 resume が機能すること, so that デプロイをまたいで quota wait 中の Issue が取り残されない

#### Acceptance Criteria

1. When watcher が特定 Issue の reset 予定時刻を読み出すとき, the Issue Watcher shall まずローカルファイルに当該 Issue の reset 予定時刻があるか参照する
2. If ローカルファイルに当該 Issue の有効な reset 予定時刻が存在しないとき, the Issue Watcher shall 当該 Issue body 内の既存 marker `<!-- idd-claude:quota-reset:<epoch>:v1 -->` を読取のフォールバックとして参照する
3. When ローカルファイルと Issue body marker の両方に当該 Issue の reset 予定時刻が存在するとき, the Issue Watcher shall ローカルファイルの値を優先して採用する
4. The Issue Watcher shall 既存 Issue body に残存する `<!-- idd-claude:quota-reset:<epoch>:v1 -->` marker の読取を本変更後も解釈可能な状態に保つ

### Requirement 4: 読取・書込の return 契約と堅牢性の維持

**Objective:** As a 既存挙動に依存する呼び出し元, I want 永続化先を変えても読取・書込関数の return 契約と安全側挙動が保たれること, so that quota 検知・自動 resume の上位フローが本変更の影響を受けない

#### Acceptance Criteria

1. When reset 予定時刻のローカルファイル書込が成功したとき, the Issue Watcher shall 永続化成功を表す return 0 を呼び出し元に返す
2. If reset 予定時刻のローカルファイル書込が失敗したとき, the Issue Watcher shall 失敗を warn ログに記録した上で呼び出し元を fail させず、ラベル付け替え等の後続副作用を継続させる
3. When 特定 Issue の reset 予定時刻が読取に成功したとき, the Issue Watcher shall 当該 epoch（整数）を標準出力に返し、found を表す return 0 を返す
4. If 特定 Issue の reset 予定時刻がローカルファイル・本文 marker のいずれにも存在しないとき, the Issue Watcher shall 数値以外を返さず、absent を表す return 1 を返す
5. If 永続化ファイルが破損している、または読み出した値が整数 epoch として解釈できないとき, the Issue Watcher shall 数値以外を返さず、return 1（absent or malformed）として扱う
6. If reset 予定時刻の読取が return 1（absent or malformed）であるとき, the Issue Watcher shall 当該 Issue の `needs-quota-wait` ラベルを自動除去せず、後続 cron tick の再判定または人間判断に委ねる

### Requirement 5: escalation コメントと新方式の整合

**Objective:** As a quota wait コメントを読む運用者, I want escalation コメントの手動介入手順が「本文 marker を書かない」新方式と矛盾しないこと, so that コメント指示どおりに操作して期待どおり手動介入できる

#### Acceptance Criteria

1. When watcher が quota 超過検知時に escalation コメントを投稿するとき, the Issue Watcher shall 当該コメントに、新方式で存在しない Issue body の `<!-- idd-claude:quota-reset:...:v1 -->` 行を削除するよう求める手順を含めない
2. Where escalation コメントが quota 起因でないと判断した場合の手動介入手順を案内する, the Issue Watcher shall 新方式で観測可能な操作（`needs-quota-wait` を `claude-failed` に手動付け替えする等）のみを案内し、本文 marker 削除のような新方式で効果を持たない操作を案内しない
3. When watcher が escalation コメントを投稿するとき, the Issue Watcher shall 検知 Stage 種別と reset 予定時刻（UNIX epoch および ISO 8601）を従来どおり明記する

### Requirement 6: ドキュメント整合

**Objective:** As a 新規 contributor, I want README の Quota-Aware Watcher 記述が新しい永続化方式を反映していること, so that ドキュメントとコードの永続化先の食い違いに惑わされない

#### Acceptance Criteria

1. The Documentation shall README の Quota-Aware Watcher 節の永続化に関する記述を、reset 予定時刻を Issue body marker ではなくローカル watcher 環境内のファイルに保存する旨に更新する
2. The Documentation shall README に記載された escalation コメント例の手動介入手順を、本文 marker 削除手順を含まない新方式の文面に更新する
3. Where README に既存 Issue body marker の後方互換読取に関する記述が必要である, the Documentation shall 移行期に本文 marker をフォールバック読取することを README に記載する

## Non-Functional Requirements

### NFR 1: 後方互換性（env var / exit code / ラベル遷移契約）

1. The Issue Watcher shall 既存環境変数 `QUOTA_AWARE_ENABLED` / `QUOTA_RESUME_GRACE_SEC` の名前・受理形式・既定値（`true` / `60`）を本変更によって変更しない
2. While `QUOTA_AWARE_ENABLED=false`（明示 opt-out）である間, the Issue Watcher shall 本変更導入前と同一の挙動（quota 検知・永続化・自動 resume をいずれも行わない）を保持する
3. The Issue Watcher shall `needs-quota-wait` ラベルの付与タイミング（quota 超過検知時）・除去タイミング（reset 予定時刻 + `QUOTA_RESUME_GRACE_SEC` 経過後の Quota Resume Processor による自動除去）・`claude-failed` を同時付与しない契約を本変更によって変更しない
4. The Issue Watcher shall reset 時刻読取関数の return 契約（0=found / 1=absent or malformed）および書込関数の return 契約（0=persisted / 1=failure, warn only）を本変更によって変更しない

### NFR 2: 観測可能性

1. While `QUOTA_AWARE_ENABLED=true` である間, the Issue Watcher shall reset 予定時刻のローカル永続化成功・失敗および読取の found/absent を `LOG_DIR` 配下のログから事後に判別できる粒度で記録する
2. The Issue Watcher shall reset 関連ログ行に Issue 番号と reset 予定時刻（UNIX epoch）を含め、grep による事後検索を可能にする

### NFR 3: 静的解析クリーン

1. The Issue Watcher script shall `shellcheck` 実行において本変更による新規警告を 0 件に保つ

### NFR 4: 冪等性

1. When 同一 Issue・同一 epoch で reset 予定時刻の永続化を複数回実行したとき, the Issue Watcher shall 永続化結果を 1 件の最新値に収束させ、重複エントリを残さない

## Out of Scope

- ARG_MAX / コマンドライン長制限への対処（Issue 確認事項 2 で GitHub の 65,536 文字本文上限が一般的な ARG_MAX を十分下回り実害なしと判断済み。本変更では扱わない）
- 複数マシン / GitHub Actions ランナー間での reset 時刻共有（人間判断で Option A を採用しローカルファイル管理とした結果、クロスマシン共有は対象外）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への同等変更
- 既存 Issue body に残存する `<!-- idd-claude:quota-reset:...:v1 -->` marker の能動的な一括削除・クリーンアップ（読取フォールバックとして残すのみで、削除作業は行わない）
- quota 検知ロジック（`rate_limit_event` の解析方式・status 判定）の変更（#66 の挙動を流用）
- 自動 resume の grace period 算出ロジック（`QUOTA_RESUME_GRACE_SEC` の意味・既定値）の変更
- ローカル永続化ファイルの世代管理 / TTL / 古いエントリの自動 vacuum（resume 済み Issue のエントリ掃除は本変更の必須要件としない）

## Open Questions

なし
