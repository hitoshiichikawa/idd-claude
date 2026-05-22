# Requirements Document

## Introduction

idd-claude の Developer エージェントは現状、独立した tool 呼び出し（複数ファイルの Read、
Glob と Grep の組み合わせ、git status / diff / log の状態確認など）を直列に実行する傾向があり、
直近の観測では tool call/turn 比率が約 1.7（104 calls / 61 turns）にとどまっています。本来は
1 つの assistant message 内で parallel tool call として束ねられる操作も別 turn に分かれているため、
turn 消費が不要に膨らみ、Opus 4.7 の context / 予算を実装本体ではなく往復に費やしてしまう
原因となっています。本要件は umbrella Issue #132（Developer エージェントの効率改善シリーズ）の
一環として、`.claude/agents/developer.md` に並列化規律を明文化し、tool call/turn 比率を
2.5+ に引き上げることを目的とします。スコープは Developer 向けドキュメント変更が主軸であり、
harness の自動計測機構や他エージェントへの展開は本要件では扱いません。

## Requirements

### Requirement 1: developer.md への並列化規律の明文化

**Objective:** As a idd-claude 運用者, I want Developer エージェント定義に独立 tool 操作の並列化規律が明示されていること, so that Developer が独立 tool 呼び出しを反射的に 1 turn にまとめ、turn 消費を圧縮できる

#### Acceptance Criteria

1. The Developer Agent Definition shall `.claude/agents/developer.md` 内に「independent な tool 操作は 1 turn にまとめる」旨の規律ステートメントを 1 件以上含める
2. The Developer Agent Definition shall 並列化すべき具体例を 3 件以上記載する（複数ファイル Read / Glob と Grep の組み合わせ / git status・diff・log 等の状態確認系 Bash の同時実行を含む）
3. The Developer Agent Definition shall 直列実行すべきケースを 2 件以上記載する（後続 tool 引数が前の結果に依存するケース / Edit 後の検証 Read 等の順序依存ケースを含む）
4. The Developer Agent Definition shall 「1 turn あたり 2〜3 tool call を目安に」という数値ガイドを 1 件以上含める
5. When 規律が既存セクション「TaskCreate / TaskUpdate の使用制限」または「実装フロー」と並ぶ独立節として追加される場合, the Developer Agent Definition shall 既存節の見出し階層・既存規約（checkbox 進捗追跡 / Feature Flag Protocol 等）と矛盾しない位置に配置する
6. Where 並列化を抑制すべき例外がある場合, the Developer Agent Definition shall 当該例外（過度な並列化による context 肥大化リスク等）を 1 件以上注意書きとして記載する

### Requirement 2: tool call/turn 比率の改善確認

**Objective:** As a idd-claude 運用者, I want Developer 実行ログから tool call/turn 比率を軽量に確認できる手順が定義されていること, so that 本変更の効果を harness 改修なしで検証できる

#### Acceptance Criteria

1. The Implementation Notes shall `impl-notes.md` に tool call/turn 比率を ad-hoc で集計する手順（ログ取得元・カウント方法・サンプル対象 Issue 範囲）を 1 件以上記載する
2. When 本変更の merge 後に 1 件以上の Developer 実行ログをサンプルとして集計する, the 集計結果 shall tool call/turn 比率の目標値 2.5+ に対する到達状況を `impl-notes.md` または PR 本文に記録する
3. If サンプル集計で 2.5+ に到達しない場合, the Implementation Notes shall 未達の原因仮説（規律の明文化が不足 / 対象 Issue が直列依存中心 / その他）と次の改善提案を 1 件以上記載する
4. The 集計手順 shall 自動 harness 改修や追加 CLI ツール導入を前提としない（既存ログ閲覧と手動カウントで完結する範囲に限定する）

### Requirement 3: 複数ファイル参照シナリオでの手動スモーク検証

**Objective:** As a idd-claude 運用者, I want 複数ファイル参照を要する代表シナリオで parallel tool call が発生することを手動で確認できる手順が定義されていること, so that 本リポジトリに unit test framework がなくとも検証手順が成果物に残る

#### Acceptance Criteria

1. The Implementation Notes shall 複数ファイル参照を要する代表シナリオ（例: 3 件以上の関連ファイルを同時に Read する場面）の手動スモーク検証手順を 1 件以上記載する
2. When 手動スモーク検証を実行する, the Verification Procedure shall 実行対象 Issue（または再現用プロンプト）・観測対象（assistant message 内の tool call 件数）・合否判定基準（同一 message 内に 2 件以上の tool call が含まれること）を明示する
3. If 手動スモーク検証で parallel tool call が観測されない場合, the Implementation Notes shall 観測されなかった事実と原因仮説を記録し、developer.md の規律記述を見直す指針を 1 件以上残す

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Developer Agent Definition shall 既存の Feature Flag Protocol 採否確認フロー・impl-resume / tasks.md 進捗追跡規約・TaskCreate / TaskUpdate 使用制限の各規約を変更せず温存する
2. While 本変更が `.claude/agents/developer.md` のみを編集対象とする, the Repository Template shall 他テンプレートファイル（`.claude/rules/*.md` / `CLAUDE.md` / `local-watcher/bin/*` 等）の挙動を変更しない

### NFR 2: ドキュメント可読性

1. The Developer Agent Definition shall 並列化規律の節を 80 行以内に収める（既存節の冗長化を避けるため）
2. The Developer Agent Definition shall 具体例を bullet list / コードフェンス等の構造化された形式で記述し、散文のみで列挙しない

### NFR 3: 言語方針整合性

1. The Developer Agent Definition shall CLAUDE.md 「言語方針」節に従い、節本文を日本語ベース・識別子と tool 名（`Read` / `Glob` / `Grep` / `Bash` / `Edit` 等）を英語固定で記述する

## Out of Scope

- harness（`local-watcher/bin/issue-watcher.sh` 等）への tool call/turn 比率の自動集計機能の追加
- 他エージェント（PM / Architect / Reviewer / Project Manager）への並列化規律の同時適用
- TaskCreate / TaskUpdate 使用制限規約の変更（umbrella Issue #132 配下の別 Issue #134 で扱う）
- tool 自体の並列実行性能の改善（Claude Code SDK 本体の挙動変更）
- parallel tool call の発生有無を自動判定する CI チェック / lint の追加
- developer.md 以外の `.claude/agents/*.md` の構造リファクタ

## 確認事項

以下の項目は Issue 本文の「確認事項」に記載されていたが、本 requirements.md 確定時点で
人間からの決定コメントが入っていないため、Developer 実装フェーズ着手前に PM / 人間判断を仰ぐ
こととし、現時点では推測で確定しない:

1. **計測手法の選択**: Requirement 2 は ad-hoc 集計に寄せた軽量要件としているが、将来的に
   harness スクリプトへの自動計測機能追加（別 Issue 切り出し）に発展させるか否かは未決定。
   本要件では ad-hoc 集計のみを必須とし、自動化は Out of Scope に置いている
2. **「2〜3 tool call/turn」目安の Issue 種別依存性**: 直列依存が支配的な Issue（spec
   読み込み → 順次実装 → commit のような線形フロー）では 2.5+ 達成が構造的に困難な可能性が
   ある。Requirement 2.3 で未達時の原因仮説記録を必須としているが、目安値そのものを Issue
   種別で動的に変える運用ルールにするか否かは未決定
3. **過度な並列化による context 肥大化リスク**: NFR / Requirement 1.6 で例外注意書きを必須化
   しているが、具体的な「並列化を抑制すべき件数閾値」（例: 1 turn あたり 5 件以上は避ける等）
   を数値で示すべきか否かは未決定。現時点では定性的な注意書きにとどめ、観測データの蓄積後に
   別 Issue で数値化を検討する
