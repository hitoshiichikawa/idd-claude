# 実装ノート: Issue #134 (TaskCreate / TaskUpdate 使用制限)

## 概要

Developer エージェント定義 (`developer.md`) に、内部 TODO トラッキング機能 (TaskCreate /
TaskUpdate) の使用を「`tasks.md` に存在しない緊急対応のみ」に明示的に制限する規約を追加した。
self-hosting (`.claude/agents/developer.md`) と consumer 配布用
(`repo-template/.claude/agents/developer.md`) の 2 ファイルを同期更新。

実装は **エージェント定義 (markdown) の規約追加** であり、コード実装やテストフレームワーク
追加ではない。本リポジトリは bash + markdown + GitHub Actions YAML 構成で unit test
フレームワークを持たないため、検証は静的解析と grep ベースの sanity check で行う。

## 変更ファイル

- `.claude/agents/developer.md` — 新規節「TaskCreate / TaskUpdate の使用制限」を `## impl-resume
  / tasks.md 進捗追跡規約` 節の直後・`# テスト作成ルール` 節の直前 (line 134 付近) に追加
- `repo-template/.claude/agents/developer.md` — 同等の節を同等の位置 (line 124 付近) に追加。
  既存の構成差分 (per-task loop / BLOCKED 節は repo-template にのみ存在) を踏襲して、
  共通部分のみ同期する方針を維持

## 受入基準のマッピング (Req → 実装位置)

各 numeric AC ID について、`.claude/agents/developer.md` (self-hosting) の対応行番号を示す。
`repo-template/.claude/agents/developer.md` も同等の節 (line 124 付近以降) に同一規約を持つ。

| AC ID | 内容 | self-hosting 対応位置 |
|---|---|---|
| 1.1 | tasks.md が唯一のタスクリスト・TaskCreate 複製禁止 | L150-156「### tasks.md は唯一のタスクリストである」節 |
| 1.2 | 許容ケースの限定列挙 | L161-181「### TaskCreate / TaskUpdate の許容ケースの限定列挙」節 |
| 1.3 | 2 具体例 (緊急 sub-step / 人間追加依頼) を含む | L166-181 (1 項 緊急 sub-step + 2 項 人間追加依頼) |
| 1.4 | 既存タスク行に対する TaskCreate 禁止 | L154-156 (`tasks.md` に既に対応するタスク行が存在する場合の禁止) |
| 1.5 | 進捗の正本は checkbox | L143-148「### 進捗の正本は checkbox である」節 + 既存 L110-115 (#133 規約) への参照 |
| 2.1 | 反射的 TaskCreate 禁止 | L189-190 (reminder 受領しても反射的に呼ばない) |
| 2.2 | reminder を進捗追跡変更指示として扱わない | L191-192 (checkbox 維持) |
| 2.3 | reminder 受領後の TaskCreate は許容ケース限定 | L193-196 (許容ケースの限定列挙への参照) |
| 3.1 | harness 側 reminder 抑制 (best effort) | 後述「Req 3 の取り扱い」節を参照 |
| 3.2 | best effort 不可時は Req 1/2 prompt 強化のみで成立 | 後述「Req 3 の取り扱い」節を参照 |
| 3.3 | エージェント定義単独で成立する状態を維持 | Req 1/2 の規約により成立。harness 側変更なし |
| 3.4 | 抑制適用範囲は Developer subagent に限定 | harness 側変更なし (Req 3.2 倒れ) |
| 4.1 | tool call 集計可能性 | 既存の Developer 実行ログ (`local-watcher/log/`) で集計可能 (追加実装なし) |
| 4.2 | 10% 以下を達成目標 | 達成目標は requirements 側で定義済み。本 PR では計測手段の維持のみ |
| 4.3 | 10% 超過時の追加対策起票 | watcher operator 責務 (本 PR 範囲外) |
| 4.4 | 手動集計可能粒度 | 既存ログ構造を維持 (追加実装なし) |
| 5.1〜5.4 | 受入確認シナリオ | 後述「受入確認シナリオの位置付け」節を参照 |
| 6.1 | 既存 impl-resume 節と矛盾しない | NFR 1.3 と整合。新規節は前節を参照する形で重複回避 |
| 6.2 | Feature Flag Protocol 採否判定フロー改変なし | 既存節 (L21-32) は無変更 |
| 6.3 | tool 一覧 (Read, Write, Edit, Bash, Grep, Glob) 変更なし | frontmatter (L4) 無変更 |
| 6.4 | #133 規約と矛盾せず参照で整合性維持 | L143-148 が #133 の checkbox 規約を参照 |
| 6.5 | install.sh ハイブリッド safe-overwrite 挙動維持 | install.sh 無変更。既存 `.bak` once-only 挙動で更新可能 |
| NFR 1.1 | 他ルールと矛盾なし | ears-format / requirements-review-gate / design-review-gate / tasks-generation / feature-flag いずれとも矛盾なし (Bash grep で確認) |
| NFR 1.2 | 言語非依存 | 規約は実装言語に依存しない (環境変数名や bash 規約への言及なし) |
| NFR 1.3 | 既存「impl-resume」節と物理的に重複しない | 新規節は前節を **参照** する形 (L138-141 / L155「前節」表記) で記述。同一規約の再記載は L143-148 の Req 1.5 部分のみ (NFR 1.3 が許容する「再掲によって整合性を維持」に該当 / Req 6.4) |
| NFR 2.1 | 4 規約が grep 可能キーワードで明示 | 「TaskCreate / TaskUpdate の使用制限」「許容ケースの限定列挙」「reminder への defensive 応答禁止」「進捗の正本は checkbox」の 4 つのキーワードを節見出しに配置 |
| NFR 3.1 | self-hosting で動作 | `.claude/agents/developer.md` (root) も同期更新済み。次回 cron 実行で本ファイルが Developer subagent prompt として参照される |

## Req 3 の取り扱い (harness 側 reminder 抑制の調査結果)

**結論: 現時点では subagent-specific な system reminder 抑制は技術的に不可能。Req 3.2 に倒れ
(prompt 強化単独で要件成立)、harness 側は変更しない。**

### 調査内容

1. **Claude CLI の関連オプション**: `claude --help` を実行し、reminder / TaskCreate / TaskUpdate
   関連オプションを検索した結果、以下が判明:
   - `--disallowedTools` / `--allowedTools` / `--tools`: ツール allowlist / denylist を制御
     できるが、これは **session 全体** に適用される。subagent 単位での制御機構は CLI フラグ
     としては露出していない
   - 仮に `--disallowedTools TodoWrite` 等で内部 TODO ツール自体を無効化した場合、Reviewer /
     PjM 等の他 subagent でも影響する (Req 3.4 違反)。本 Issue は **Developer subagent に
     限定** した抑制を求めているため不適合
2. **issue-watcher.sh の現状**: `grep -nE 'reminder|TaskCreate|TaskUpdate|system-reminder'` で
   検索した結果、該当する処理は **0 件**。watcher は subagent 起動時に system reminder を
   生成・抑制する処理を持たない (Claude Code SDK 内部で生成される)
3. **「task tools haven't been used」reminder の出所**: 本 reminder は Claude Code SDK
   (harness) が内部で session state に応じて自動注入するものであり、watcher script や
   prompt template から制御する手段は現時点で確認できない

### 判断

- Req 3.1 (技術的に可能ならば抑制) → **不可能と判明したため未適用**
- Req 3.2 (不可能ならば prompt 強化のみで成立) → **本ケースに該当**。Req 1 / 2 のエージェント
  定義側の prompt 強化のみで要件成立とする
- Req 3.3 (エージェント定義単独で成立する状態を維持) → **満たす**
- Req 3.4 (抑制適用範囲を Developer に限定) → harness 側変更なしのため自動的に満たす

将来 Claude Code SDK が subagent-specific reminder suppression API を提供した場合は別 Issue
として再検討する余地がある。

## 受入確認シナリオの位置付け (Req 5)

Req 5.1〜5.4 の受入確認シナリオは、本 PR の merge 後に **実際の Developer 実行ログを
観察** することでのみ計測可能 (本 PR は規約追加で、シナリオは subagent 起動時の挙動を
測定対象とするため)。本 PR では以下の措置に留める:

- 本 PR では受入確認シナリオの **手動 e2e 実施は行わない** (PR 内では計測不能)
- 本 PR merge 後の次回以降の Developer 実行ログから、watcher operator が以下の手順で
  10% 閾値を確認する:

### 計測手順 (本 PR merge 後に watcher operator が実施)

```bash
# 1. 計測対象の Developer 実行ログを特定 (本 PR merge 後の Issue 起票分)
ls -lt $HOME/.issue-watcher/log/ | head

# 2. 該当ログから tool call 数を集計 (例: claude-debug ログから)
log_file="<path/to/developer-execution-log>"

# 3. TaskCreate / TaskUpdate (または同等の TodoWrite) 呼び出し数を grep
task_calls=$(grep -cE 'TaskCreate|TaskUpdate|TodoWrite' "$log_file")

# 4. 全 tool call 数を grep (tool_use イベント等)
total_calls=$(grep -cE 'tool_use|tool_call' "$log_file")

# 5. 比率を計算
echo "scale=2; $task_calls * 100 / $total_calls" | bc
# 期待: 10 以下 (Req 4.2)
```

(上記は手順の概念例。実際の grep pattern は watcher のログ形式 / Claude SDK の出力形式に
合わせて調整する)

### 4 シナリオの位置付け

- Req 5.1 (全タスクが tasks.md で完結する通常実行): TaskCreate 使用率が 10% 以下なら
  本 PR の規約が機能していると判断
- Req 5.2 (緊急 sub-step が発生する実行): TaskCreate 呼び出しが許容ケース 1 に該当する
  形で発生していれば許容
- Req 5.3 (人間追加依頼が入る実行): TaskCreate 呼び出しが許容ケース 2 に該当する形で
  発生していれば許容
- Req 5.4 (10% 超過時の対応): watcher operator が結果を記録し、追加調整の要否を判断

## 確認事項 (Reviewer / 人間レビュワー判断ポイント)

1. **新規節の配置位置**: `## impl-resume / tasks.md 進捗追跡規約` 節の直後・`# テスト作成
   ルール` 節の直前 (root 版 L134 / template 版 L124) に挿入したが、別の位置 (例: `# 実装
   ルール` 節内のサブ節など) のほうが Developer から目に留まりやすい可能性がある。位置の
   妥当性をレビュワーに判断してもらいたい
2. **「許容ケース 2 件」の具体例の数**: 本 PR では requirements.md の Open Questions 1 の
   暫定 stance に従い、Architect 判断委任先 (Architect 不在の Issue) では PM 暫定 stance
   どおり **2 ケースで確定** した。さらに具体例を増やす (例: 別プロセス CI failure /
   一時的調査 spike 等) かは、merge 後の運用ログを見てから別 Issue で追加判断する想定
3. **「進捗の正本」の二重記述**: NFR 1.3 (物理的に重複しない) に対し、root 版では L110-115
   (既存 #133 規約) と L143-148 (新規 Req 1.5 節) の 2 箇所で「進捗の正本は checkbox」が
   言及される。これは NFR 1.3 が許容する「参照または再掲によって整合性を維持」(Req 6.4)
   の範囲内と判断したが、レビュワーが冗長と判断する場合は新規節 L143-148 を「前節 L110-115
   を参照」のみに縮約する案もありうる
4. **repo-template の構造差分**: root 版 (`.claude/agents/developer.md`, 234 行) と template
   版 (`repo-template/.claude/agents/developer.md`, 317 行) は per-task loop / BLOCKED 節
   など本 Issue 範囲外の理由で既に差分がある。今回追加した新規節は両方に存在し内容も等価
   だが、template 版では既存 L100-117 (impl-resume 節) に「タスク完了 = checkbox 編集」の
   明示文がない (root 版 L110-115 にのみあり)。本 PR の新規節 L133-140 (template) が
   Req 1.5 を自己完結で再掲する形で整合性を担保している
5. **Req 3 (harness 側抑制)**: 上記「Req 3 の取り扱い」節のとおり、Claude Code SDK の
   subagent-specific reminder 抑制は現時点で不可能と判定した。CLI フラグや SDK ドキュメント
   を改めて精査して見落としがないかを Reviewer に再確認してもらう余地がある (Req 3.1 が
   実は適用可能であった場合は別 Issue として harness 側実装を追加)

## 派生タスク (次の Issue として切り出すべき候補)

- **Claude Code SDK の subagent-specific reminder suppression API の追跡**: 将来 SDK が
  該当 API を提供した場合に再検討する別 Issue
- **TaskCreate 使用率の自動計測ダッシュボード**: 本 PR では手動集計に留めた (Req 4.4 / Out
  of Scope) が、umbrella #132 の長期計測のため自動集計の起票余地あり
- **他エージェント定義への TaskCreate 制限の波及検討**: 本 Issue は Developer 限定 (Out of
  Scope) だが、Reviewer / PjM / Architect でも同様の overhead 観測がされた場合は別 Issue
  として横展開

## 静的検証

本リポジトリは unit test フレームワークを持たないため、以下の grep ベース sanity check で
規約キーワードの存在を確認:

```bash
# self-hosting 版に 4 つの grep 可能キーワード (NFR 2.1) が存在することを確認
grep -nE "TaskCreate / TaskUpdate の使用制限|許容ケースの限定列挙|defensive 応答禁止|進捗の正本は checkbox" \
  .claude/agents/developer.md
# 期待: 4 行ヒット (各見出し)

# repo-template 版も同等に存在
grep -nE "TaskCreate / TaskUpdate の使用制限|許容ケースの限定列挙|defensive 応答禁止|進捗の正本は checkbox" \
  repo-template/.claude/agents/developer.md
# 期待: 4 行ヒット (各見出し)

# 2 ファイルが共通の規約節を持つことを確認 (詳細 diff は構造差分を含むため必須ではない)
grep -c "## TaskCreate / TaskUpdate の使用制限" \
  .claude/agents/developer.md repo-template/.claude/agents/developer.md
# 期待: 各 1 件
```

shellcheck / actionlint は本 PR では bash / yaml 変更がないため対象外。

## Feature Flag Protocol 採否確認結果

本リポジトリの `CLAUDE.md` には `## Feature Flag Protocol` 節が存在しないため、**opt-out**
として解釈した (Req 1.3 / NFR 1.1)。opt-in 時の追加実装フロー (flag 命名・両系統テスト・
クリーンアップ等) は適用しない。
