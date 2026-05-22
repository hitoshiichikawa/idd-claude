# Implementation Notes

Issue #135（feat(developer): independent な tool 操作を 1 turn にまとめて parallel call で
実行する規律を強化）の Developer 実装ノートです。本 Issue は umbrella Issue #132（Developer
エージェントの効率改善シリーズ）配下の 1 件で、`.claude/agents/developer.md` への並列化
規律の明文化が主軸の docs-only 変更です。

## 変更概要

- `.claude/agents/developer.md` および `repo-template/.claude/agents/developer.md` の両方に
  新規 h1 節「Tool 呼び出しの並列化規律（Issue #135 以降適用）」を追加した（self-hosting
  整合のため両方を同じ内容に更新）
- 節は `# 実装ルール` の直後・`# 実装フロー` の直前に配置し、既存節（`## opt-in 時の追加
  実装フロー` / `## impl-resume / tasks.md 進捗追跡規約` / `## TaskCreate / TaskUpdate の
  使用制限`）の見出し階層と内容を変更していない（Req 1.5 / NFR 1.1）
- 節の行数は 66 行（NFR 2.1 の 80 行以内に収まっている）

## 受入基準の達成確認

本リポジトリには unit test framework が無いため、各 AC は **ドキュメント記述の有無**で
担保する。担保箇所は `.claude/agents/developer.md` の該当節の同一内容を
`repo-template/.claude/agents/developer.md` にも複製済み（self-hosting）。

### Requirement 1: developer.md への並列化規律の明文化

| AC | 担保箇所 | 確認内容 |
|---|---|---|
| 1.1 | `## 規律ステートメント（Req 1.1）` | 「independent な tool 操作は 1 turn にまとめる」ステートメントを 1 件記載 |
| 1.2 | `## 並列化すべき具体例（Req 1.2）` | 複数ファイル Read / Glob+Grep 組み合わせ / 状態確認系 Bash の 3 件を bullet で列挙 |
| 1.3 | `## 直列にすべきケース（Req 1.3）` | 「後続 tool 引数が前の結果に依存」「Edit 後の検証 Read」の 2 件を bullet で列挙 |
| 1.4 | `## 数値ガイド（Req 1.4）` | 「1 turn あたり 2〜3 tool call を目安に」を 1 件明記、加えて tool call/turn 比率 2.5+ 目標も併記 |
| 1.5 | h1 節の配置位置 | `# 実装ルール` と `# 実装フロー` の間に独立 h1 として追加。既存 h2 節（opt-in / impl-resume / TaskCreate）は変更せず温存 |
| 1.6 | `## 過度な並列化への注意（Req 1.6）` | 「1 turn 5 件以上で context 肥大化リスク」「目安 4 件以下」の注意書きを 1 件記載 |

### Requirement 2: tool call/turn 比率の改善確認

#### tool call/turn 比率の ad-hoc 集計手順（AC 2.1, 2.4）

idd-claude は harness 自動計測機構を持たないため、以下の手順で **既存 watcher ログから手動で
カウント** する。追加 CLI ツール導入は不要（AC 2.4 を満たす）。

1. **ログ取得元**: `local-watcher/logs/<YYYYMMDD>/<HHMMSS>-issue-<N>-impl-*.log`（watcher が
   各 Issue 実行ごとに生成する Claude Code session ログ）
2. **tool call カウント方法**: 当該ログを開き、`tool_use` block の発生件数を数える。Claude
   Code の出力形式に応じて以下のいずれか:
   - `assistant` message の中に出現する `<tool_use>` 開始タグ件数
   - JSON ログの場合は `jq '[.[] | select(.type=="tool_use")] | length'` 相当
   - 単純な文字列マッチで近似する場合は `grep -c '^Tool: '` 等の prefix 行数を数える
     （ログフォーマットは watcher バージョンで差があるため要事前確認）
3. **turn カウント方法**: 同ログで `assistant` role の message 件数を数える（tool_use を
   含まない純粋な text 応答も 1 turn として数える）
4. **比率算出**: tool call 件数 / turn 件数 を計算し、小数 2 桁で記録
5. **サンプル対象 Issue 範囲**: 本変更 merge 後の **直近 3 件の impl 系 Issue 実行ログ**
   （iteration / resume を含む）をサンプルとして集計する。複数ファイル参照を伴う Issue を
   優先的に選ぶ

#### 集計結果の記録（AC 2.2, 2.3）

- 本 Developer フェーズ時点では merge 前のためサンプル集計は未実施。**merge 後に PjM もしくは
  運用者が直近 3 件の Developer 実行ログから tool call/turn 比率を集計し、PR 本文または
  本 `impl-notes.md` 末尾の「post-merge 計測結果」セクションに追記する**（AC 2.2）
- **2.5+ 未達時の原因仮説候補**（AC 2.3 への先行記載）:
  - 規律の明文化が不足（具体例の網羅性が低い / 数値ガイドが弱い）→ developer.md を再強化
  - 対象 Issue が直列依存中心（spec 読み込み → 順次実装 → commit の線形フロー）→ 目安値の
    Issue 種別依存性を確認事項として PM に差し戻す（後述「確認事項」項 2）
  - 過度な並列化への注意書きが defensive に効きすぎている → 「4 件以下」目安の閾値を見直す
- 改善提案候補:
  - Issue 種別ごとに目標比率を分ける運用ルール化（線形フロー Issue は 2.0+、調査系 Issue
    は 3.0+ 等）
  - 別 Issue として harness 側に tool call/turn ログ集計ヘルパを追加（本 Issue Out of Scope）

### Requirement 3: 複数ファイル参照シナリオでの手動スモーク検証

#### 手動スモーク検証手順（AC 3.1, 3.2）

複数ファイル参照を要する代表シナリオで parallel tool call が発生することを確認する手順:

1. **実行対象 Issue（再現用プロンプト）**: 以下のいずれか
   - 本 Issue (#135) の Developer 実行ログ自体（本タスクで `.claude/agents/developer.md` /
     `repo-template/.claude/agents/developer.md` / `CLAUDE.md` 等 3 件以上を同時 Read している
     ことを期待）
   - 後続の impl 系 Issue で `requirements.md` / `design.md` / `tasks.md` の 3 件を同時に
     参照する場面（spec 読み込みフェーズ）
2. **観測対象**: Claude Code の Developer 実行ログから、**assistant message 単位での tool call
   件数**を確認する。具体的には:
   - 同一 `assistant` role message 内に複数の `tool_use` block が含まれているか
   - Read 系操作が連続する場面で、別 message に分割されず 1 message に集約されているか
3. **合否判定基準**:
   - **合格**: spec 読み込みフェーズ（または同種の独立 Read フェーズ）の少なくとも 1 箇所で、
     同一 assistant message 内に **2 件以上の tool call** が含まれている
   - **不合格**: spec 読み込みフェーズが全て 1 message / 1 tool call で分割されており、parallel
     call が観測されない

#### 検証未達時の対応（AC 3.3）

手動スモーク検証で parallel tool call が観測されなかった場合、以下を記録し developer.md を
見直す:

- **観測されなかった事実**: 対象 Issue 番号 / 該当 message の context（spec 読み込み / git
  状態確認 / その他）
- **原因仮説候補**:
  - 規律ステートメントが Developer prompt の冒頭で目に入っていない → 節の配置順を見直す
    （現状は `# 実装ルール` 直後、より手前への移動を検討）
  - 「並列化すべき具体例」の表現が抽象的 → 具体的なシナリオ列挙を追加
  - 「過度な並列化への注意」が defensive に解釈されている → 注意書きの文言を緩和
- **見直し指針**: developer.md の規律記述を、未達ケースで観測された具体的な失敗パターンに
  基づき強化する（推測ではなく観測ベース）

## 確認事項（requirements.md 末尾の未決事項を引き継ぎ）

PM 確定済み requirements.md の末尾「確認事項」項目を本実装フェーズでも未決のまま引き継ぐ。
現時点では推測で確定せず、merge 後の運用観測と PM / 人間の判断を待つ:

1. **計測手法の選択**: 本 Requirement 2 は ad-hoc 集計を必須としており、将来的に harness
   スクリプトへの自動計測機能追加（別 Issue 切り出し）に発展させるか否かは未決定。本要件
   では ad-hoc 集計のみを必須とし、自動化は Out of Scope に置いている
2. **「2〜3 tool call/turn」目安の Issue 種別依存性**: 直列依存が支配的な Issue（spec
   読み込み → 順次実装 → commit のような線形フロー）では 2.5+ 達成が構造的に困難な可能性が
   ある。Requirement 2.3 で未達時の原因仮説記録を必須としているが、目安値そのものを Issue
   種別で動的に変える運用ルールにするか否かは未決定
3. **過度な並列化による context 肥大化リスクの数値化**: 本実装では「目安として 4 件以下に
   抑える」と定性的な閾値を記載した。具体的な「並列化を抑制すべき件数閾値」を数値で示すべきか
   否かは観測データ蓄積後に別 Issue で検討する

## 実装上の判断

- **節の配置位置**: `# 実装ルール` 直後 / `# 実装フロー` 直前を選択した。理由:
  - 規律ステートメントは「実装フロー実行中の各 turn で意識すべき」内容であり、フロー本文の
    前置きとして読まれる位置が自然
  - 既存 `# 実装ルール` 節と並列の h1 として独立配置することで、`## opt-in` / `## impl-resume`
    / `## TaskCreate` の既存 h2 節と階層が混ざらない（Req 1.5 / NFR 1.1）
- **両ファイルの同一内容更新**: root の `.claude/agents/developer.md`（idd-claude 自身の
  self-hosting 用）と `repo-template/.claude/agents/developer.md`（consumer repo に配置される
  テンプレート）の両方に同じ節を追加した。CLAUDE.md「禁止事項」の「`repo-template/**` の
  破壊的変更を、既 installed の consumer repo への影響評価なしに入れる」に該当しないか確認:
  - 追加は **新規節の追加** であり、既存節の見出し階層・既存規約を変更していない
  - 既 installed の consumer repo は次回 `install.sh` 再実行時に上書きされる設計（既存挙動）
  - 内容は docs-only かつ Developer エージェントの runtime 挙動指針であり、watcher / labels
    / cron 文字列等の運用契約には影響しない
  - したがって migration note は不要と判断
- **既存節のリファクタは行わない**: NFR 1.1 / 1.2 に従い、`## TaskCreate / TaskUpdate の
  使用制限` 等の既存節は一切変更していない。本 Issue のスコープは並列化規律の追加のみ

## ドッグフーディング観察

本 Issue 実装自体が「複数ファイル参照シナリオでの parallel tool call」の好例となるよう、
実装フェーズの初期 turn で以下を 1 message にまとめて Read した:

- `docs/specs/135-feat-developer-independent-tool-1-turn-p/requirements.md`
- `.claude/agents/developer.md`
- `repo-template/.claude/agents/developer.md`

これにより 3 件の Read を 1 turn に圧縮できた（tool call/turn 比率改善の実証例）。
今後 Requirement 3 の手動スモーク検証で本ログをサンプルとして利用可能。
