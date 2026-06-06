# Requirements Document

## Introduction

#289 (PR #290) で README / QUICK-HOWTO.md に `per-task-implementer-failed` /
`error_max_turns` 対応の Troubleshooting 節が新設されたが、運用現場では「turn-heavy な
親タスクが `error_max_turns` で溢れた後に、実際に **tasks.md をどう編集し、どの順で
ラベル操作して resume させるか**」の具体的な復旧手順がまだ不足しており、運用者が
独力で安全に再実行に持ち込めない状態になっている。本 spec ではこの不足を埋めるため、
#289 で作られた Troubleshooting 節に「分割復旧手順」サブセクションを追記し、診断 →
分割設計 → tasks.md フラット化編集 → commit & push → ラベル復旧 → 監視という 6 ステップ
を順序通り提示する。なお Issue #291 本文で言及されていた per-task ループの親 / 子
ディスパッチ順是正（コード変更）は人間判断によりスコープ外として別 Issue に切り出す
方針が確定しており、本 spec は **ドキュメント追記のみ** で完結する。watcher 本体・
agent 定義・既存 env / ラベル契約は本 spec では一切変更しない。

## Requirements

### Requirement 1: 分割復旧手順サブセクションの追加

**Objective:** As a idd-claude の運用者, I want turn-heavy な親タスクが
`error_max_turns` で詰まったときに「どの順で何を操作すれば再実行に持ち込めるか」を
README から手順としてたどりたい, so that 推測に頼らず安全に復旧操作を完了できる

#### Acceptance Criteria

1. The README shall #289 で追加された `per-task-implementer-failed` /
   `error_max_turns` 対応 Troubleshooting 節の配下に「分割復旧手順」サブセクションを
   1 つ追加する
2. The 分割復旧手順サブセクション shall (1) 診断 → (2) 分割設計 → (3) tasks.md
   フラット化編集 → (4) commit & push → (5) ラベル復旧 → (6) 監視 の 6 ステップを
   この順序で提示する
3. The 分割復旧手順サブセクション shall 各ステップにおいて運用者が観測すべき入力
   （ログ・ラベル・git 履歴等）と、運用者が実行すべき操作（tasks.md 編集・git
   コマンド・gh ラベル操作）を分けて記述する
4. Where QUICK-HOWTO.md が `per-task-implementer-failed` / `error_max_turns` の
   入口を提供している場合, the QUICK-HOWTO.md shall 分割復旧手順への相互リンクを
   持ち、運用者が 1 クリックで README の該当サブセクションへ到達できる
5. The 分割復旧手順サブセクション shall 既存の #289 Troubleshooting 節の h2 / h3
   階層と整合する見出しレベル（h4 以下）で配置され、既存の「症状」「原因」
   「診断手順」「対応の優先順位」「復旧手順」記述を上書きしない

### Requirement 2: 粒度変更と設計変更の分岐基準

**Objective:** As a idd-claude の運用者, I want 「粒度のみの変更で済むケース」と
「設計まで作り直すケース」をドキュメント上で判断できる基準を持ちたい, so that
不要な design iteration ゲートを通したり、逆に設計影響のある変更を in-branch 編集
だけで済ませてしまったりする事故を防げる

#### Acceptance Criteria

1. The 分割復旧手順サブセクション shall 「粒度のみ変更で済むケース」を **in-branch
   編集で対応可能** と位置付け、その判断条件（File Structure Plan・Components 境界
   ・Interfaces に手を入れずに済む等、観測可能な条件）を列挙する
2. The 分割復旧手順サブセクション shall 「設計まで作り直すケース」を **design
   iteration（Architect 再起動）が必要** と位置付け、その判断条件（File Structure
   Plan の改訂・Components 追加・契約変更が必要等）を列挙する
3. When 運用者が 2 つの分岐基準のどちらに該当するかを判断したとき, the 分割復旧手順
   サブセクション shall それぞれの分岐先で取るべき次アクション（in-branch 編集 vs
   design iteration ラベル付与等）を明示する
4. The 分割復旧手順サブセクション shall 判断に迷うケースの取り扱い（人間判断への
   エスカレーション、PR 本文の「確認事項」での共有等）を明示する

### Requirement 3: tasks.md フラット化編集の規約

**Objective:** As a idd-claude の運用者, I want turn-heavy な親タスクをフラット化して
tasks.md を編集する際に、既存の進捗・トレーサビリティ・並列マーカーを破壊しない規約を
ドキュメントで知りたい, so that resume 機能（impl-resume）の進捗追跡と Architect が
付与したアノテーションが壊れない

#### Acceptance Criteria

1. The 分割復旧手順サブセクション shall `done 済み` の checkbox 行（`- [x]` で始まる
   タスク行）を編集対象から除外し、不変として保持することを明示する
2. The 分割復旧手順サブセクション shall フラット化後のタスク行が
   `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` の各アノテーションを
   保持することを明示する
3. The 分割復旧手順サブセクション shall フラット化により tasks.md と design.md
   の File Structure Plan に齟齬が出る可能性があることを警告として記述する
4. When File Structure Plan と tasks.md の間に齟齬が生じたとき, the 分割復旧手順
   サブセクション shall PR 本文の「確認事項」セクションでその齟齬を明記する運用を
   案内する
5. The 分割復旧手順サブセクション shall numeric 階層 ID（`1` / `1.1` / `2` 等）の
   採番方針として、既存 ID を温存しつつフラット化で新規追加するタスクを最上位 ID
   として追番する旨を示す
6. The 分割復旧手順サブセクション shall フラット化編集後の tasks.md が
   `repo-template/.claude/rules/tasks-generation.md` 既存規約（checkbox 必須化・
   Budget overflow check・numeric ID 階層）と矛盾しないことを明示する

### Requirement 4: ラベル復旧手順（impl PR 有無別）

**Objective:** As a idd-claude の運用者, I want 分割復旧操作完了後のラベル復旧手順を
「impl PR 無し」「impl PR 有り」別に示してほしい, so that ラベル操作順序の誤りで
進行中の PR を破壊するリスクを避けられる

#### Acceptance Criteria

1. When impl PR が存在しない状態で `claude-failed` が付与されているとき, the
   分割復旧手順サブセクション shall `claude-failed` ラベルを除去することで watcher
   が再 pickup する手順を示す
2. When impl PR が既に存在する状態で `claude-failed` が付与されているとき, the
   分割復旧手順サブセクション shall `ready-for-review` を **先に** 付与してから
   `claude-failed` を除去する順序を明示する
3. If 運用者が impl PR 存在下で `claude-failed` を先に除去した場合に発生し得る
   破壊事象がある場合, the 分割復旧手順サブセクション shall その破壊事象の概要と
   回避策を、本文と視覚的に区別できる警告ブロックとして記述する
4. The 分割復旧手順サブセクション shall ラベル復旧後の期待状態（残るラベル・次に
   watcher または人間レビュアーが取るアクション）を、impl PR の有無別に明示する
5. The 分割復旧手順サブセクション shall ラベル復旧手順を運用者が実行する操作
   （ラベル付与・除去の順序）として記述し、watcher 内部実装の関数名やコードパスには
   踏み込まない

### Requirement 5: 既存運用との整合性

**Objective:** As a idd-claude の運用者, I want 分割復旧手順が #270 / #263 や
impl-resume 温存規約・進捗追跡コミット運用と矛盾しないことを保証してほしい,
so that ドキュメント追記により既存運用の一貫性が崩れない

#### Acceptance Criteria

1. The 分割復旧手順サブセクション shall #270 / #263 で確立された既存 per-task
   ループ運用（progress tracking / done 済み行の扱い等）と矛盾しない記述に留める
2. The 分割復旧手順サブセクション shall impl-resume の進捗追跡（`- [ ]` ↔ `- [x]`
   の markdown checkbox を進捗の正本とする運用）を温存することを明示する
3. The 分割復旧手順サブセクション shall 進捗追跡コミット（`progress(impl-resume):
   ...` 等の commit 規約）が分割復旧操作後も継続することを明示する
4. The 分割復旧手順サブセクション shall #289 で追記された「対応の優先順位」（(1)
   タスク粒度の是正 → (2) `DEV_MAX_TURNS` 引き上げ → (3) 手動仕上げ）と整合する
   位置付け（本サブセクションは (1) の具体操作手順として接続）を明示する

### Requirement 6: 後方互換の保持

**Objective:** As a 既に idd-claude を導入しているリポジトリの運用者, I want 本 spec
の適用が既存挙動を一切変えないことを保証してほしい, so that ドキュメント変更だけで
watcher / agent / ラベル契約が壊れる事故を避けられる

#### Acceptance Criteria

1. The 本 spec の成果物 shall 既存の env 変数名（`DEV_MAX_TURNS` /
   `PR_ITERATION_MAX_TURNS` / `DEV_MODEL` 等）の名称・意味・既定値を変更しない
2. The 本 spec の成果物 shall 既存ラベル（`claude-failed` /
   `per-task-implementer-failed` / `ready-for-review` 等）の名称・付与契約・遷移
   意味を変更しない
3. The 本 spec の成果物 shall 既存の watcher / agent の挙動を変更せず、README /
   QUICK-HOWTO.md のドキュメント追記のみで完結する
4. The 本 spec の成果物 shall #289 (PR #290) で追記済みの既存 Troubleshooting 節
   本文を削除・改変せず、分割復旧手順サブセクションを **追記** する形を取る
5. The 本 spec の成果物 shall root の `.claude/rules/*.md` と
   `repo-template/.claude/rules/*.md` の byte 一致規約（CLAUDE.md「二重管理」節）に
   影響を与えない（本 spec は rules ファイルを編集しない）

## Non-Functional Requirements

### NFR 1: 発見容易性

1. The 分割復旧手順サブセクション shall README 目次から #289 Troubleshooting 節
   経由で 1 ホップ以内に到達できる位置に配置される
2. The QUICK-HOWTO.md shall README の分割復旧手順サブセクションへの相互リンクを
   持ち、双方向のナビゲーションが成立する
3. The 分割復旧手順サブセクション shall 検索キーワード（`turn-heavy` / `分割復旧`
   / `tasks.md フラット化` 等、運用者が想起しやすい語）を見出しまたは本文に含める

### NFR 2: 安全性（破壊操作の回避）

1. The 分割復旧手順記述 shall ラベル操作の順序（`ready-for-review` 先付与 →
   `claude-failed` 後除去）を実行手順の中で必ず明示する
2. The 分割復旧手順記述 shall 順序を誤った場合のリスクを警告ブロック（blockquote
   または注意書き）として、手順本文と視覚的に区別できる形で記載する
3. The tasks.md 編集記述 shall `done 済み [x]` 行・既存アノテーションの保持を
   明示し、誤って削除した場合の影響（impl-resume の進捗ロスト等）に触れる

### NFR 3: 言語・スタイル整合

1. The 本 spec の成果物 shall CLAUDE.md「言語方針」に従い、日本語ベースで記述する
   （識別子・env 変数名・ラベル名・コマンド名等の英語固定語彙を除く）
2. The 本 spec の成果物 shall #289 で確立された Troubleshooting 節の語彙・記述
   スタイル（節構造・blockquote 警告・コードフェンス言語タグ等）と整合する

## Out of Scope

- per-task Implementer ループの親 / 子タスクディスパッチ順是正（コード変更）。
  Issue #291 本文で言及されていた (B) スコープは別 Issue に切り出す。本 spec
  完了後に **follow-up Issue を起票する責務** がワークフロー側に残る
- `local-watcher/bin/issue-watcher.sh` および `.claude/agents/*.md` の挙動変更
- 自動的なタスク分割・自動的な `DEV_MAX_TURNS` 引き上げ・turn 消費の動的調整等の
  ロジック実装
- `DEV_MAX_TURNS` のデフォルト値変更（60 を維持）
- 既存 env 変数名・ラベル名・watcher 出力フォーマットの変更
- #289 で追記済みの Troubleshooting 節本文の書き換え・整理（本 spec は追記のみ）
- root の `.claude/rules/*.md` および `repo-template/.claude/rules/*.md` の追記
  （本 spec は README / QUICK-HOWTO.md のみを編集対象とする）
- 特定リポジトリ（ab-extweb 等）固有の対処手順
- `error_max_turns` 以外の Implementer 失敗モード（panic / OOM / 529 過負荷等）に
  対する分割復旧手順（必要なら別 Issue で扱う）

## Open Questions

- **配置位置の詳細**: 分割復旧手順を #289 Troubleshooting 節内のどの位置（「復旧
  手順」直下 / 「対応の優先順位」(1) 直下 / 節末尾の独立サブセクション）に置くかは
  Architect / 人間レビュアーの判断に委ねる。本要件は NFR 1.1 の「1 ホップ以内」と
  Req 1.5 の階層整合さえ満たせばよい
- **PR 本文への follow-up Issue 起票宣言の書式**: (B) ディスパッチ是正の別 Issue
  起票を本 spec の PR 本文「確認事項」で宣言する際の書式（Issue タイトル案・
  `Split from: #291` の canonical 記法採用等）は PjM / 人間が確定する事項として残す

## 関連

- Split from: #289
- Related: #270 #263 #289
