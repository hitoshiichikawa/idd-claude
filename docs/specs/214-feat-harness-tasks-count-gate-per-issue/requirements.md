# Requirements Document

## Introduction

idd-claude の Tasks Count Gate（#147）は、Architect が `tasks.md` を確定した直後に
タスク件数を機械的に再カウントし、件数が `TC_ESCALATE_LOWER`（既定 11 件）以上のとき
`needs-decisions` ラベルを付与して Developer 自動起動 / impl-resume を抑止する harness ガードです。
しかし per-task-loop（#21、`PER_TASK_LOOP_ENABLED=true`）運用では各タスクが独立 turn budget を持つため、
1 タスクあたりは小さいまま合計件数だけが閾値を超える正当なケースが発生し、ガードが誤発火します。
現状の回避策（件数削減・閾値引き上げ・gate 全体の無効化）はいずれも証跡が残らない／安全性を犠牲にするため、
**人間が個別 Issue に対し理由付きで明示的に例外続行を宣言でき、その判断が証跡として恒久的に残る** per-issue override 機構が必要です。
本要件はその user/operator-observable な振る舞いを定義し、シグナル方式の最終確定は `design.md`（Architect）に委ねます。

## Requirements

### Requirement 1: override による Developer 続行許可

**Objective:** As a watcher 運用者, I want エスカレーション閾値を超えた個別 Issue に対し例外続行を宣言できる機構, so that per-task-loop で正当に件数が多い Issue を抑止されずに Developer まで進められる

#### Acceptance Criteria

1. When tasks.md のタスク件数が `TC_ESCALATE_LOWER` 以上で、かつ当該 Issue に理由付きの有効な override 宣言が存在する状態で Architect 完了直後の判定が走ったとき, the Tasks Count Gate shall `needs-decisions` ラベルを当該 Issue に付与しない
2. When override が honor され `needs-decisions` が付与されなかったとき, the Tasks Count Gate shall 当該 Issue を後続の Developer 自動起動 / impl-resume の候補として残す（候補抽出から除外しない）
3. While 当該 Issue に有効な override 宣言が存在する間, the Tasks Count Gate shall タスク件数が `TC_ESCALATE_LOWER` 以上であっても Developer / impl-resume の続行を許可する
4. When タスク件数が `TC_ESCALATE_LOWER` 未満のとき, the Tasks Count Gate shall override 宣言の有無にかかわらず本機能導入前と同一の判定（normal / warn）を適用する

### Requirement 2: 証跡記録

**Objective:** As a 運用者・レビュワー, I want override が適用された事実と理由・件数・宣言者を機械可読な証跡として残してほしい, so that 後から「誰がいつ何件のどんな理由で例外を許可したか」を追跡できる

#### Acceptance Criteria

1. When override が honor され Developer 続行が許可されたとき, the Tasks Count Gate shall 検知件数・宣言者（actor）・宣言理由を含むレコードを `tasks-count:` prefix のログ行として記録する
2. When override が honor されたとき, the Tasks Count Gate shall 当該 Issue に検知件数・宣言者・宣言理由を含むコメントを 1 件投稿する
3. While 同一 Issue で override が継続して honor され続ける間, the Tasks Count Gate shall 同等内容の証跡コメントを後続サイクルで重複投稿しない（証跡コメントは冪等であること）

### Requirement 3: 理由欠落時の fail-safe

**Objective:** As a 運用者, I want 理由なき例外宣言を無効として扱ってほしい, so that 証跡の無い無条件バイパスが成立せず安全側に倒れる

#### Acceptance Criteria

1. If override 宣言は存在するが justification（理由）が欠落しているとき, the Tasks Count Gate shall その宣言を無効とみなし override を honor しない
2. When justification 欠落により override が無効とみなされたとき, the Tasks Count Gate shall タスク件数が `TC_ESCALATE_LOWER` 以上であれば本機能導入前と同一の通常エスカレーション（`needs-decisions` 付与 + エスカレーションコメント投稿）を適用する
3. When justification 欠落により override が無効化されたとき, the Tasks Count Gate shall その旨と理由欠落の事実を `tasks-count:` prefix のログ行として記録する

### Requirement 4: シグナル解釈が曖昧・不完全な場合の fail-safe

**Objective:** As a 運用者, I want override シグナルの解釈が曖昧または不完全なときは例外を honor しないでほしい, so that 想定外の入力で誤って抑止解除されるリスクを避けられる

#### Acceptance Criteria

1. If override シグナルの解釈が曖昧または不完全（必要な構成要素を判定できない）であるとき, the Tasks Count Gate shall override を honor せず安全側（エスカレーション）に倒す
2. When シグナル解釈の曖昧さにより override が honor されなかったとき, the Tasks Count Gate shall 曖昧と判定した事実を `tasks-count:` prefix のログ行として記録する

### Requirement 5: 恒久性（再付与抑止）

**Objective:** As a 運用者, I want 一度宣言した override が後続サイクルでも効き続けてほしい, so that 毎サイクル `needs-decisions` を手動除去し続ける運用負荷を負わずに済む

#### Acceptance Criteria

1. While 当該 Issue に有効な override 宣言が存在する間, the Tasks Count Gate shall 後続サイクルで当該 Issue に `needs-decisions` ラベルを再付与しない
2. When override 宣言が当該 Issue から取り除かれ、かつタスク件数が依然 `TC_ESCALATE_LOWER` 以上の状態で次サイクルの判定が走ったとき, the Tasks Count Gate shall 通常どおりエスカレーション（`needs-decisions` 付与）を適用する

### Requirement 6: per-issue スコープ

**Objective:** As a 運用者, I want override が宣言された Issue 単位でのみ効くようにしてほしい, so that 1 件の例外宣言が他 Issue の判定挙動を意図せず変えない

#### Acceptance Criteria

1. The Tasks Count Gate shall override 宣言の効果を、その宣言が付与された Issue のみに限定する
2. When ある Issue に override 宣言が存在し、別の Issue にはそれが存在しない状態で各 Issue の判定が走ったとき, the Tasks Count Gate shall 宣言の無い Issue に対しては本機能導入前と同一の判定を適用する

### Requirement 7: bot による override 自動付与の禁止

**Objective:** As a 運用者, I want override が人間の明示操作によってのみ成立することを保証してほしい, so that watcher 自身の動作によって例外が自己発火しガードが空洞化することを防げる

#### Acceptance Criteria

1. The Tasks Count Gate shall override 宣言シグナル（例外続行を成立させる識別子）を watcher 自身が自動付与しない
2. The Tasks Count Gate shall override の成立判定を、watcher が決して自動生成しない識別子の存在に依拠させる
3. If watcher 自身の動作のみで生成され得るシグナルしか存在しないとき, the Tasks Count Gate shall それを有効な override 宣言として扱わない

### Requirement 8: ハード上限による runaway 防止

**Objective:** As a 運用者, I want 任意のハード上限を設定でき、それを超える件数では override を無視できるようにしてほしい, so that 極端に肥大化した tasks.md が override で無制限に通過する runaway を防げる

#### Acceptance Criteria

1. Where ハード上限（`TC_HARD_MAX` 相当）が設定されている場合に、タスク件数がそのハード上限を超えたとき, the Tasks Count Gate shall 有効な override 宣言が存在しても override を honor せず通常どおりエスカレーションする
2. Where ハード上限が設定されていない、またはタスク件数がハード上限以下の場合, the Tasks Count Gate shall override の honor 判定を Requirement 1 に従って適用する
3. When ハード上限超過により override が無視されたとき, the Tasks Count Gate shall 上限超過の事実と件数を `tasks-count:` prefix のログ行として記録する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. When 当該 Issue に override 宣言が存在しないとき, the Tasks Count Gate shall 本機能導入前（#147 既定）と同一の判定（normal / warn / escalate）を適用する
2. The Tasks Count Gate shall 既存の公開環境変数名（`TC_ENABLED` / `TC_WARN_LOWER` / `TC_WARN_UPPER` / `TC_ESCALATE_LOWER`）の意味と既定値を変更しない
3. While `TC_ENABLED` が `true` 以外（opt-out）の間, the Tasks Count Gate shall override 判定を含む本機能全体を実行しない（本機能導入前と完全一致）
4. The Tasks Count Gate shall 既存ラベル名（`needs-decisions`）の意味と既存の候補抽出挙動を、override 非適用ケースにおいて変更しない

### NFR 2: 可観測性

1. The Tasks Count Gate shall override の honor / 無効化 / ハード上限による無視のすべての判定結果を `tasks-count:` prefix のログ行として `grep` で抽出可能な形式で記録する
2. The Tasks Count Gate shall override 由来の Issue コメントを、本機能由来と機械的に判別できる固定識別子を含む形式で投稿する

### NFR 3: 信頼性（fail-open / fail-safe の両立）

1. If override 判定に必要な外部情報取得（Issue ラベル / コメント参照等）が失敗したとき, the Tasks Count Gate shall override を honor せず安全側（既存エスカレーション挙動）に倒す
2. If 証跡コメント投稿やログ記録の副作用が失敗したとき, the Tasks Count Gate shall watcher 全体の処理を中断させずに続行する（fail-open）

## Out of Scope

- `TC_WARN_LOWER` / `TC_WARN_UPPER` / `TC_ESCALATE_LOWER` の既定値変更（本機能は閾値そのものを変えない）
- Architect 側 budget overflow gate（#131、`design.md` の `## Split Proposal` 生成）の挙動変更
- per-task-loop（#21）自体の判定・分割挙動の変更
- override シグナルの具体的方式の確定（専用ラベル名・コメントマーカー文字列・grep パターン・bash 関数名・env var の実装詳細）— `design.md`（Architect）の領分
- override 宣言の動的失効（有効期限・件数連動での自動失効など）。本要件では「宣言が存在する間は有効」とのみ規定する
- 複数リポジトリ横断での override 共有（per-issue かつ単一 repo スコープに限定）

## Open Questions

- **シグナル方式の最終確定**: Issue 本文は案A（専用ラベル例 `tc-override` + 構造化コメントマーカー `<!-- idd-claude:tc-override reason="..." -->` で理由を証跡化）を推奨。案B（コメントマーカーのみ）・案C（tasks.md 内宣言ブロック）も候補。Requirement 2 / 3 / 7 を満たす方式であれば Architect が design.md で確定してよい。
- **ハード上限（Requirement 8）を本リリースに含めるか**: Issue 本文では optional 扱い。`TC_HARD_MAX` の env var 名・既定値（未設定＝無制限とするか）を含め、導入要否を人間に確認したい。
- **override honor 時の warning / escalation コメント残置**: override で続行を許可した場合でも警告コメントを別途残すか、証跡コメント 1 件に集約するか（Requirement 2.2 との重複可否）。
- **Issue クローズ / 再オープン時の override 有効範囲**: 一度 honor された Issue が close → reopen された場合に override 宣言を再評価するか、宣言シグナルが残っていれば引き続き honor するか（Requirement 5 の恒久性との整合）。
- **actor（宣言者）の取得元**: 証跡に記録する actor を、宣言シグナル（ラベル付与者 / コメント投稿者）のどこから取得するか。watcher は人間トークンで動くため actor 文字列だけでは bot 操作と区別できない点（Requirement 7）と整合させる必要がある。
