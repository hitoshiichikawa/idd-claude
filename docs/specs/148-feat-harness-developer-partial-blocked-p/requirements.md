# Requirements Document

## Introduction

現状の Developer エージェントの出力契約は「stage done」「stage failed」の 2 値のみで、
「タスクの一部を外部要因（未 merge の依存 Issue / 設計矛盾 / 環境不備）でブロックされて
完了できなかった」「turn budget 残量が安全な commit に不足した」状態を表現できない。
このため Developer が halt せざるを得ない場合でも impl-notes.md に halt 理由を書いて
「Branch is ready for the Reviewer stage」と疑似 escalation するしかなく、orchestrator は
Stage A 完了として Reviewer を起動し、Reviewer は DoD 未達成で機械 reject、redo で残タスク
一括投入により turn budget が爆発するという無駄サイクルが発生している（Case study: KeyNest #99
で $29 浪費）。

本機能では、Developer 出力契約に新規 status code `partial_blocked` / `partial_overrun` の 2 種を
1st-class シグナルとして追加し、orchestrator は Reviewer 起動を skip して `needs-decisions` ラベル
付与とエスカレーションコメント投稿で人間判断に委ねるフローへ切り替える。これにより、無駄な
Reviewer 起動と redo サイクルを未然に抑止し、Developer が「halt せざるを得ない」と自己判断した
時点で即座に人間にエスカレーションできる契約を確立する。

Issue 本文の確認事項 #1（`partial_overrun` の trigger 判定主体）は人間判断で **Option A
（Developer 自己判断）** と確定済みであり、本要件は Developer prompt に閾値を明記して
Developer 自身が判断する設計を前提に組み込む。orchestrator 側の新規 turn count 監視インフラは
本 Issue のスコープ外とする。

## Requirements

### Requirement 1: Developer 出力契約への新規 status code 追加

**Objective:** As an idd-claude harness operator, I want Developer エージェントが「全完了」と
「全失敗」の中間状態を明示的に報告できるようにしたい, so that 部分完了の状態を後段の
orchestrator が機械的に解釈して適切なフローに分岐できる。

#### Acceptance Criteria

1. The Developer agent output contract shall `partial_blocked` を新規 status code として定義する。
2. The Developer agent output contract shall `partial_overrun` を新規 status code として定義する。
3. The Developer agent output contract shall 既存の `complete` status code の意味と互換性を改変しない。
4. When Developer が `partial_blocked` を report するとき, the Developer agent shall halt 理由
   （依存している外部要因の具体 ID または事象）と残タスク一覧（tasks.md の `- [ ]` 行）を
   出力に含める。
5. When Developer が `partial_overrun` を report するとき, the Developer agent shall halt 時点で
   既に commit 済みのタスク範囲と残タスク一覧を出力に含める。

### Requirement 2: Developer 自己判断による partial_overrun 報告

**Objective:** As an idd-claude harness operator, I want Developer 自身が turn budget 残量を
監視して `partial_overrun` を自己判断で報告できるようにしたい, so that orchestrator 側に
新規の turn count 監視インフラを追加せず、prompt 改修のみで partial_overrun 検出を成立させ
られる。

#### Acceptance Criteria

1. The Developer prompt shall turn budget 残量が一定閾値（既定値 残 10 turn）を下回ったとき
   `partial_overrun` を自己判断で報告する条件を明記する。
2. The Developer prompt shall 外部依存（未 merge の Issue / 環境不備 / 設計矛盾）で進行不能と
   判断したとき `partial_blocked` を自己判断で報告する条件を明記する。
3. The Developer prompt shall `partial_blocked` / `partial_overrun` の報告が failure ではなく
   意図的な escalation であり人間判断を仰ぐためのものである旨を明記する。
4. The Developer prompt shall `partial_overrun` 報告時に「現在のターンで安全に commit 可能な
   範囲で停止すること」を指示として明記する。

### Requirement 3: orchestrator による partial status の処理

**Objective:** As an idd-claude harness operator, I want Developer が `partial_blocked` または
`partial_overrun` を報告したとき orchestrator が Reviewer を起動せず人間エスカレーション
フローへ切り替えるようにしたい, so that DoD 未達成が自明な状態で Reviewer を無駄起動する
ことによる token 浪費と機械 reject ループを回避できる。

#### Acceptance Criteria

1. When Developer が `partial_blocked` を report したとき, the Issue Watcher shall Reviewer
   エージェントの起動を skip する。
2. When Developer が `partial_overrun` を report したとき, the Issue Watcher shall Reviewer
   エージェントの起動を skip する。
3. When Developer が `partial_blocked` を report したとき, the Issue Watcher shall 当該 Issue
   に `needs-decisions` ラベルを付与する。
4. When Developer が `partial_overrun` を report したとき, the Issue Watcher shall 当該 Issue
   に `needs-decisions` ラベルを付与する。
5. When Developer が `complete` 以外（`partial_blocked` / `partial_overrun` のいずれか）を
   report したとき, the Issue Watcher shall 当該時点で既に local に存在する commit を破棄せず
   remote branch に push する。
6. When Developer が `partial_blocked` または `partial_overrun` を report したとき, the Issue
   Watcher shall 当該 Issue にエスカレーションコメントを 1 件投稿する。

### Requirement 4: エスカレーションコメントの記載事項

**Objective:** As an idd-claude operator, I want エスカレーションコメントを読むだけで halt の
原因と残作業・推奨対処を把握できるようにしたい, so that 人間が Issue を開いて手動で残作業の
判断と分岐ができる。

#### Acceptance Criteria

1. The escalation comment shall halt 理由（Developer の自己申告内容）を含める。
2. The escalation comment shall 当該時点で push 済みの commit 一覧（SHA とコミットメッセージ
   要約）および branch 名を含める。
3. The escalation comment shall 残タスク一覧（tasks.md の `- [ ]` 行を抽出した形）を含める。
4. The escalation comment shall 推奨アクション（依存 Issue を先に進める / Issue を分割する /
   手動で続行する 等の選択肢）を含める。
5. The escalation comment shall 報告された status code （`partial_blocked` / `partial_overrun`）
   を識別可能な固定文字列として含める。

### Requirement 5: dispatcher による needs-decisions の pickup 抑止

**Objective:** As an idd-claude harness operator, I want `needs-decisions` ラベル付き Issue を
次サイクル以降の自動 pickup 対象外として扱う既存挙動が本機能由来の付与でも維持されることを
期待する, so that 人間判断待ちの Issue が自動で再 pickup されて escalation コメントが繰り返し
投稿されたり Developer が再起動したりすることを防げる。

#### Acceptance Criteria

1. While Issue に `needs-decisions` ラベルが付与されている間, the Issue Watcher shall 当該 Issue
   に対して Developer フェーズの自動起動を行わない。
2. While Issue に `needs-decisions` ラベルが付与されている間, the Issue Watcher shall 当該 Issue
   に対して Reviewer フェーズの自動起動を行わない。
3. When 人間が `needs-decisions` ラベルを Issue から除去したとき, the Issue Watcher shall 次
   サイクル以降で当該 Issue を通常の pickup 候補として再評価する。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Developer agent shall 本機能導入前と同じ条件で `complete` を report する場合の出力
   フォーマットを破壊しない（既存の Round 1 / Round 2 経路で挙動が変化しないこと）。
2. The Issue Watcher shall 既存の env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`,
   `BASE_BRANCH`, `DEV_MODEL` 等）の意味と互換を破壊しない。
3. The Issue Watcher shall 既存のラベル遷移契約（`auto-dev` → `claude-claimed` →
   `awaiting-design-review` / `claude-picked-up` / `needs-decisions` / `ready-for-review` /
   `claude-failed`）の他のラベル名・意味を本機能で改変しない。
4. When Developer が `complete` を従来通り report したとき, the Issue Watcher shall 本機能
   導入前と user-observable に同一のフェーズ遷移（Reviewer 起動）を実行する。

### NFR 2: 観測可能性

1. When Issue Watcher が `partial_blocked` または `partial_overrun` を検出したとき, the Issue
   Watcher shall 検出事実と Issue 番号・status code を運用者が後から `grep` 等で抽出できる
   ログ行として標準出力または既定のログファイルに記録する。
2. The escalation comment shall 当該コメントが本機能由来であることを後段の運用で識別できる
   固定文字列を含める（NFR は Requirement 4.5 と同一の文字列でよい）。

### NFR 3: フェイルセーフ

1. If Developer の出力が `complete` / `partial_blocked` / `partial_overrun` のいずれにも該当
   しない不正な status code であったとき, the Issue Watcher shall 当該 Issue に `claude-failed`
   ラベルを付与し、Reviewer 起動を skip する。
2. If Developer の出力 parse 自体が失敗したとき, the Issue Watcher shall 既存の失敗時挙動
   （`claude-failed` 付与）と互換な挙動を維持する。

## Out of Scope

- Developer の turn budget 自己監視ロジックの詳細実装（残 turn 数の取得手段・閾値判定アルゴリズム
  の具体）— Issue #131 と協調する別 Issue で扱う
- Reviewer 側で partial を `iterate` する semantics（Reviewer が partial を見て「ここまでで
  approve」を出す等）— 別の design 検討が必要なため本 Issue の範囲外
- `partial_blocked` 解消後の自動 resume 機構（人間が依存解消後にラベルを外す現状運用を維持）
- partial 状態の蓄積を跨ラウンドで構造化して引き継ぐ resume protocol の拡張（Round 1
  partial_blocked → 人間解消 → Round 2 自動継続のような完全自動化）
- orchestrator 側でターン数を外部から監視する新規インフラの導入（確認事項 #1 で
  Option A 確定済みのため不採用）
- Developer 以外のエージェント（Triage / PM / Architect / Reviewer）の出力契約変更
- Consumer repo（KeyNest 等）の既存 PR / Issue への retroactive 適用（過去事例の遡及救済）

## Open Questions

Issue 本文の確認事項 #1（`partial_overrun` の trigger 判定主体）は人間判断で
**Option A（Developer 自己判断）** と確定済みのため Requirement 2 に組み込み、Open Question
からは除外する。以下は引き続き人間判断が必要な論点として残置する。

1. **`needs-decisions` ラベルの意味多重化**（Issue 確認事項 #2 由来）: 既存運用で
   `needs-decisions` は PM フェーズの情報不足時、Issue #131 由来の Architect 側 budget
   overflow 検知時、Issue #147 由来の tasks.md 件数 overflow 時、そして本機能由来の
   partial_blocked / partial_overrun 検知時の 4 系統で付与されることになる。本要件は
   Requirement 4.5 / NFR 2.2 でコメント本文の識別文字列により由来を区別する方針を採用したが、
   専用補助ラベル（例: `harness-partial-blocked` / `harness-partial-overrun`）を併用して
   機械フィルタを容易にすべきかは人間判断としたい。
2. **複数 round 跨ぎの partial 蓄積と resume の整合**（Issue 確認事項 #3 由来）: Round 1 が
   `partial_blocked` → 人間が依存解消 → Round 2 で続行というシナリオで、impl-notes.md /
   tasks.md / 残タスク情報の引き継ぎ方法を resume protocol（Stage Checkpoint Resume 等）と
   どこまで整合させるかが未確定。本要件は「partial 解消後の自動 resume」を Out of Scope と
   したが、人間が手動で次サイクルを起動する際の引き継ぎ手順（残タスクの読み取り元・
   impl-notes.md の追記規約）は本機能着手後に運用知見を蓄積してから別途仕様化したい。
3. **Developer prompt の turn budget 閾値（既定 残 10 turn）の妥当性**: 本要件は Issue 本文の
   提案値 10 turn をそのまま採用したが、Developer の `MAX_TURNS` 既定値や実際の commit
   1 件あたりの turn 消費量に対する余裕度の根拠が暫定値である。Issue #131 の budget overflow
   事前検知の運用知見と突き合わせて再評価する基準を設けるべきかを人間判断したい。
