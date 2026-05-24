# Requirements Document

## Introduction

self-hosting 運用中の idd-claude 本体 repo では、Phase E Path Overlap Checker が delay 状態の Issue に付与する `awaiting-slot` ラベルが live repo に存在せず、delay 状態が運用者に不可視になっていた。原因はラベル定義スクリプトの **双方向ドリフト**にある。template 側 (`repo-template/.github/scripts/idd-claude-labels.sh`) には `awaiting-slot` 定義があるが root コピー (`.github/scripts/idd-claude-labels.sh`) には無く、逆に root の一部ラベルには #54 由来の description prefix（`【Issue 用】` / `【PR 用】`）が付いているが template 側には付いていない。さらに、template にラベルを追加しても既 install 済みの repo に自動伝播しない伝播ギャップがある。本 spec はこの 2 観点（root 同期・install.sh 経由の冪等伝播）を扱い、ラベル parity を name+color 集合レベルで担保する。watcher のフォールバック堅牢化（受入観点 3）は #187 に分離済みでスコープ外とする。

## Requirements

### Requirement 1: root labels スクリプトへの `awaiting-slot` 追加と root/template parity

**Objective:** As a 運用者, I want root の labels スクリプトが `awaiting-slot` を含み template と同じラベル集合を定義していること, so that live repo でラベル作成スクリプトを実行したときに delay 状態が可視化される

#### Acceptance Criteria

1. When 運用者が root の labels スクリプトを実行したとき, the Labels Setup Script shall `awaiting-slot` ラベル（name=`awaiting-slot`, color=`c5def5`）を含むラベル一式の作成を試みる
2. The Labels Setup Script shall root と template の両 labels スクリプトについて name+color のペア集合が一致すること（name|color レベルの parity）を満たす
3. When root への `awaiting-slot` 追加を行うとき, the 修正 shall additive（ラベルの新規追加のみ）であり、root に既存の他ラベルの name / color / description を変更しない
4. While root の既存ラベルが #54 由来の description prefix（`【Issue 用】` / `【PR 用】`）を保持している状態で, the 修正 shall root の description を template 側（prefix 無し）に合わせる書き換えを行わず、#54 の prefix を温存する
5. The parity 判定 shall description の完全一致を要求せず、name と color の集合一致のみを判定対象とする

### Requirement 2: install.sh 経由の新ラベルの冪等伝播

**Objective:** As a 既に idd-claude を install 済みの運用者, I want install.sh を再実行したときに `awaiting-slot` を含む新規ラベルが既存 repo へ確実に伝播すること, so that template にラベルが追加された後も再 install するだけで live repo のラベル集合が最新化される

#### Acceptance Criteria

1. When 運用者が install.sh を再実行したとき, the Install Script shall 配置済み labels スクリプトを対象 repo に対して起動し、未存在のラベル（`awaiting-slot` を含む）を作成する
2. While install.sh が既存ラベルを検出している状態で, the Labels Setup Script shall 当該ラベルを skip し、その name / color / description を変更しない（冪等な再実行）
3. Where install.sh のラベル自動伝播導線がすでに存在する, the spec deliverable shall その導線が `awaiting-slot` を含む新規ラベルを伝播することを README または install.sh 内コメントで明文化する
4. If install.sh 再実行時の伝播導線に不足が判明したとき, the Install Script shall その不足を補う変更を加え、新規ラベルが伝播するようにする
5. While install.sh の再実行を行っている状態で, the Install Script shall 既存ラベルの削除・改名・color 変更を一切行わない

### Requirement 3: 後方互換性の維持

**Objective:** As a 既存運用者, I want 本修正が既存の env var / exit code / ラベル名 / CLI interface を不変に保つこと, so that 既稼働の install / cron / labels 運用が壊れない

#### Acceptance Criteria

1. The Labels Setup Script shall 既存ラベルの name と color を不変に保つ（追加のみ・削除や改名をしない）
2. The Labels Setup Script shall `--repo` / `--force` の CLI オプションの意味と挙動を変更しない
3. The Install Script shall `--no-labels` フラグおよび `IDD_CLAUDE_SKIP_LABELS` 環境変数の opt-out 挙動を変更しない
4. The Install Script shall `REPO` を含む既存 env var 名と、ラベルセットアップ関連の exit code の意味を変更しない
5. While 運用者が opt-out（`--no-labels` / `IDD_CLAUDE_SKIP_LABELS`）を指定している状態で, the Install Script shall ラベル作成を実行せず、本機能導入前と同一の挙動を保つ

## Non-Functional Requirements

### NFR 1: 冪等性

1. When labels スクリプトまたは install.sh のラベル導線を 2 回連続で実行したとき, the system shall 2 回目の実行で既存ラベルを 0 件作成し、ラベル集合を 1 回目と同一状態に保つ

### NFR 2: parity 検証の自動化（should レベル）

1. Where parity 検証の自動化が含まれる, the parity 検証手段 shall root と template の name|color 集合の差分を検出して非ゼロ件の差分があれば失敗を報告する
2. The parity 検証手段の要否判断 shall requirements 確定時点で「standalone スクリプト / CI チェックを追加するか、手動確認手順の文書化に留めるか」を Open Questions または設計判断に委ねる形で明示する

### NFR 3: ドキュメント整合性

1. When ラベル集合または伝播導線の挙動を変更したとき, the deliverable shall README の該当箇所を同一変更内で更新する

## Out of Scope

- watcher フォールバック堅牢化（受入観点 3、`local-watcher/bin/issue-watcher.sh` の編集。ラベル付与失敗時の説明 sticky comment 投稿）は #187 に分離済みのため本 spec では扱わない
- root の既存ラベルの description を template 側に合わせる方向の同期（#54 を regression させるため明示的に禁止）
- template 側へ #54 の description prefix を追記する作業（本 spec は root への additive 追加のみを対象とし、template 側 prefix の retrofit は別判断とする）
- 既存ラベルの削除・改名・color 変更
- 新規外部サービス連携やラベル動的変更機構の追加
- `#177` / `#180` / `#181` のモジュール化作業そのもの（path conflict 回避の調整は運用上配慮するが、本 spec の成果物には含めない）

## Open Questions

- NFR 2.2 の parity 検証自動化について、Issue 本文では「検討」（should レベル）とされている。standalone スクリプト追加 / CI チェック追加 / 手動確認手順の文書化のいずれを採るかは Architect / 人間判断に委ねる（本 spec は parity を name|color 集合レベルで担保することのみを必須とし、自動化手段は選択肢として残す）。

## 関連

- Related: #187
