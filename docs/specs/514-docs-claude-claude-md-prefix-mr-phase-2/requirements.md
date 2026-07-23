# Requirements Document

## Introduction

CLAUDE.md「機能追加ガイドライン」§2 の prefix ⇄ module 対応表は、各 module の責務をエージェントが
最初に参照する正準インデックスである。`mr_` 行は #507（Phase 1: Triage complexity の解釈と `size:*`
ラベル永続化）時点の記述のままで、#508（Phase 2 / PR #512 merge 済み）で同 module に追加された
「`size:*` ラベル → Developer モデル解決」の責務が反映されていない。この乖離により、model-router に
触れるエージェントが Phase 2 の存在を見落とし、責務の重複実装や誤った配置判断を招く恐れがある。
本件は root `CLAUDE.md` の当該 1 行を実装の現状に追随させるドキュメント更新である。

## 関連

- Depends on: #508
- Related: #507
- Related: #509

## 用語と subject の定義

本書の AC で用いる subject は以下を指す。

| subject | 指すもの |
|---|---|
| the prefix 表 | root `CLAUDE.md`「機能追加ガイドライン」§2 の prefix ⇄ module 対応表（2 列の markdown table） |
| the mr_ 行 | 上記 prefix 表のうち prefix 列が `mr_` である 1 行 |
| the repository | idd-claude リポジトリの成果物構成全体（配布物・同期規約を含む） |

## Requirements

### Requirement 1: `mr_` 行への Phase 2 責務の追記

**Objective:** As a model-router に触れるエージェント, I want prefix 表の `mr_` 行から Phase 2 の責務を把握できること, so that 実装済みの責務を見落とさずに配置・変更判断ができる

#### Acceptance Criteria

1. The mr_ 行 shall Phase 2 の責務が Issue #508 に由来することを Issue 番号付きで示す
2. The mr_ 行 shall Phase 2 の責務として `size:*` ラベルから Developer 実行モデルを解決することを示す
3. The mr_ 行 shall Phase 2 で追加された関数名として `mr_extract_size_label` と `mr_resolve_dev_model` を示す
4. The mr_ 行 shall モデル解決に用いる設定値として `DEV_MODEL_SMALL` と `DEV_MODEL_MEDIUM` を示す
5. The mr_ 行 shall モデル解決が slot 起動時に 1 回行われ、その結果が slot 内の `DEV_MODEL` 再代入として適用されることを示す
6. The mr_ 行 shall モデルが変わる条件が gate 有効化と size 別モデル設定の明示の両方を必要とする二重 opt-in であることを示す

### Requirement 2: 既存記述の温存と表構造の非破壊

**Objective:** As a prefix 表を参照するエージェント, I want 既存の Phase 1 記述と表構造が保たれること, so that 既存の参照・引用と表の可読性が壊れない

#### Acceptance Criteria

1. The mr_ 行 shall Phase 1（#507）の責務記述（Triage complexity の解釈と `size:*` ラベル永続化）を削除・改変せずに保持する
2. The mr_ 行 shall gate `MODEL_ROUTING_ENABLED` が Phase 共通の単一 gate であり Phase 別 gate を設けない旨の既存記述を保持する
3. The mr_ 行 shall prefix 列の値を `mr_` のまま変更しない
4. The prefix 表 shall `mr_` 行の表内での並び順を変更しない
5. The prefix 表 shall `mr_` 行以外のすべての行を変更しない
6. The prefix 表 shall 2 列（prefix 列 / module・領域列）の markdown table 構造を維持し、`mr_` 行を 1 行 1 セルのまま保つ

### Requirement 3: 記述粒度と書式の整合

**Objective:** As a リポジトリのメンテナ, I want 追記が表の他行と同じ粒度・書式であること, so that 表全体の記述スタイルが揃い読み手の負担が増えない

#### Acceptance Criteria

1. The mr_ 行 shall 表の他行（`pt_` 行 / `fr_` 行 / `pr_` 行）と同水準の粒度、すなわち Issue 番号参照と責務要約を含み、関数単位の逐次仕様説明を含まない粒度で記述する
2. The mr_ 行 shall 説明部を日本語ベースで記述する
3. The mr_ 行 shall 関数名・env var 名・ラベル名・module ファイル名を英語のまま表記し、日本語へ言い換えない
4. The mr_ 行 shall 識別子（関数名 / env var 名 / ラベル名 / ファイル名）をインラインコード記法で表記する
5. The mr_ 行 shall 表セル内に改行を含めず 1 行として記述する

### Requirement 4: 変更範囲の限定

**Objective:** As a リポジトリのメンテナ, I want 変更が root CLAUDE.md の当該 1 行に閉じること, so that 配布物・consumer repo への波及と無関係な差分を避けられる

#### Acceptance Criteria

1. The repository shall 本件の変更対象を root `CLAUDE.md` の 1 ファイルに限定する
2. The repository shall 本件で root `CLAUDE.md` の変更行を prefix 表の `mr_` 行 1 行のみに限定する
3. The repository shall 本件で `repo-template/` 配下のいかなるファイルも変更しない（`CLAUDE.md` は consumer 固有であり byte 一致同期の対象外であるため）
4. The repository shall 本件で `local-watcher/` 配下のスクリプト・module・テストのいずれも変更しない
5. The repository shall 本件で `README.md` を変更しない
6. If 追記内容の正確性を保つために `mr_` 行以外の変更が必要と判明したとき, the repository shall 当該変更を本件に含めず別 Issue として切り出す

### Requirement 5: 実装・既存ドキュメントとの整合性

**Objective:** As a prefix 表を信頼して行動するエージェント, I want 記述が merge 済み実装と一致していること, so that 表の記述に基づく判断が誤らない

#### Acceptance Criteria

1. The mr_ 行 shall `local-watcher/bin/modules/model-router.sh` に実在する関数名のみを記載し、実在しない関数名を記載しない
2. The mr_ 行 shall gate 名を `MODEL_ROUTING_ENABLED` と表記し、他の gate 名を記載しない
3. The mr_ 行 shall #508 の要件文書および README「Model Routing Phase 2: size ラベル → Developer モデル (#508)」節の記述と矛盾する内容を含まない
4. The mr_ 行 shall model-router が担わない責務（gate 判定の実行 / `DEV_MODEL` への適用 / ログ出力といった呼び出し側の責務）を model-router の責務として記載しない
5. The mr_ 行 shall Phase 3（#509）に属する未実装の責務を記載しない

### Requirement 6: 検証可能性（受け入れ確認手段）

**Objective:** As a reviewer, I want 本件の受け入れ確認手段が事前に定義されていること, so that PR レビュー時に AC 充足を機械的に確認できる

#### Acceptance Criteria

1. The 検証手順 shall 変更差分が root `CLAUDE.md` の 1 ファイル・1 行の変更に収まることの確認を含む
2. The 検証手順 shall 更新後の `mr_` 行に Requirement 1 の各記載要素（#508 / `size:*` ラベルからのモデル解決 / `mr_extract_size_label` / `mr_resolve_dev_model` / `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM` / slot 起動時 1 回 / `DEV_MODEL` 再代入 / 二重 opt-in）が含まれることの確認を含む
3. The 検証手順 shall 更新後の `mr_` 行に Phase 1 記述と単一 gate 記述が残存することの確認を含む
4. The 検証手順 shall 更新後の prefix 表が markdown table として崩れていない（全行が 2 列で描画される）ことの確認を含む
5. Where 本件でコード変更を伴わないとき, the 検証手順 shall `shellcheck` / `actionlint` / 近接テストの追加を要求しない

## Non-Functional Requirements

### NFR 1: 可読性・情報密度

1. The prefix 表 shall 本件の更新によって表の行数を増やさない（追記後も `mr_` 行は 1 行のまま、表全体の行数増加は 0 行）
2. The mr_ 行 shall 追記後の記述量を表内の最長行（`impl-pipeline` 行 / `slot-worker` 行）を超えない範囲に収める

### NFR 2: ドリフト防止・保守性

1. The repository shall 本件の更新後、`diff -r .claude/agents repo-template/.claude/agents` と `diff -r .claude/rules repo-template/.claude/rules` の結果を空のまま維持する
2. The mr_ 行 shall 将来 Phase が追加された際に同じ書式で追記できるよう、Phase 単位（`Phase N（#Issue番号）: 責務`）で責務を区切って記述する

## Out of Scope

- prefix 表の `slot-worker` 行への呼び出し側関数（`_slot_apply_dev_model_routing`）の追記 — 本 Issue の対象は `mr_` 行 1 行のみ。要否は Open Questions に記載
- `README.md` の Model Routing 関連記述の追加・修正（#508 で更新済み）
- `local-watcher/bin/modules/model-router.sh` のファイル冒頭ヘッダコメントの修正（#508 で Phase 2 を記載済み）
- `repo-template/CLAUDE.md` への反映（`CLAUDE.md` は consumer 固有内容を持つため byte 一致同期の対象外）
- prefix 表の他行（`pt_` / `fr_` / `pr_` / `impl-pipeline` / `slot-worker` 等）の記述粒度統一リファクタ
- prefix 表以外の CLAUDE.md 各節（§1 配置 / §3 opt-in gate / §5 セキュリティ 等）への Model Routing 関連追記
- Phase 3（#509）の責務記載、および Phase 3 実装そのもの
- モデルルーティング機能の挙動変更（設定値 / gate / 解決規則 / ログのいずれも変更しない）
- size ラベルの運用手順・トラブルシュートの記載（README の領分）
- prefix 表の記述内容を自動検証する lint / テストハーネスの新設

## Open Questions

- **`slot-worker` 行の呼び出し側記載を別途扱うか**: #508 で `_slot_apply_dev_model_routing` が
  slot-worker.sh へ追加され、同ファイルの冒頭ヘッダには記載済みだが、CLAUDE.md の `slot-worker` 行
  の関数列挙には含まれていない。本 Issue は `mr_` 行 1 行に限定されているため本書では Out of Scope
  としたが、同種のドリフトとして別 Issue を起票するかは人間判断に委ねる。
- **表セルの記述量に関する明示規約が存在しない**: 他行の記述量は `qa_` 行（1 行 20 字程度）から
  `impl-pipeline` 行（数百字）まで幅がある。本書は NFR 1.2 で「表内の最長行を超えない」を暫定上限と
  したうえで、Requirement 3.1 で `pt_` / `fr_` / `pr_` 行と同水準の粒度を採用した。より短い粒度
  （Phase 1 記述と同程度の一文追記）を望む場合は Requirement 1 の記載要素を削る判断が必要になる。

---

## 自己レビュー結果（要件レビューゲート）

- **Mechanical Checks**: 全要件見出しが numeric ID（Requirement 1〜6 / NFR 1〜2）。各要件に EARS 形式
  AC（`The <subject> shall` / `If` / `Where`）が 1 件以上存在。関数名・env var 名・ラベル名は本件では
  「更新対象ドキュメントに記載すべき内容そのもの」であり、実装方針を規定する実装語彙ではないため
  意図的に AC 本文へ含めている（どう書くか＝文面・語順・追記位置は規定していない）。
- **EARS・テスト可能性**: 全 AC が更新後の `mr_` 行および差分から機械的に確認可能。数値は具体化済み
  （変更ファイル 1 / 変更行 1 / 表行数増加 0 / 表 2 列）。
- **スコープ・カバレッジ**: Issue 本文の 3 つの変更内容（Phase 2 責務の追記 / 既存記述の温存 / 対象を
  root CLAUDE.md 1 行に限定）をそれぞれ Requirement 1・2・4 に対応付け、PM として (a) 書式・粒度の
  整合（Req 3）、(b) 実装との事実整合（Req 5）、(c) 受け入れ確認手段（Req 6）を補完した。過剰な
  スコープ拡大を避けるため、README / module ヘッダ / repo-template / 他行の統一は明示的に Out of
  Scope へ置いた。
- **既存整合**: `local-watcher/bin/modules/model-router.sh` の実装（Phase 1 / Phase 2 双方の関数と
  責務分界）、#508 requirements.md（Req 1 / 3 / 5、二重 opt-in、slot 起動時 1 回解決）、README
  「Model Routing Phase 2」節、CLAUDE.md §4 の二重管理規約（`CLAUDE.md` は byte 一致同期対象外）と
  矛盾しないことを確認した。`repo-template/` 配下に `mr_` / model-router への言及がないことも確認済み。
- **2 パス目の補正**: 初稿では「表の書式規約」と「実装との整合」を 1 要件に混在させていたため
  Requirement 3 と Requirement 5 に分離し、1 AC = 1 挙動を担保した。また初稿にあった
  `slot-worker` 行の更新要件は Issue のスコープ（1 行のみ）を超えるため Out of Scope + Open
  Questions へ移送した。
- 残存する曖昧性は Open Questions に暫定採用値付きで列挙。レビューは 2 パスで確定。
