# Review Notes — Issue #134 (Round 1)

<!-- idd-claude:review round=1 model=claude-opus-4-7 -->

## Summary

差分は `.claude/agents/developer.md`（self-hosting 版, +68 行）と
`repo-template/.claude/agents/developer.md`（consumer 配布版, +66 行）への新規節
「## TaskCreate / TaskUpdate の使用制限（Issue #134 以降適用）」追加と、
`impl-notes.md` の新規作成のみで、boundary は requirements.md の Req 6.3 / 6.5 / Out of Scope と
完全に整合している。Req 1〜6 の全 numeric AC および NFR 1〜3 を、Developer エージェント定義の
規約追加と impl-notes.md の調査結果記録によりカバーしている。Req 3 (harness 側抑制) は Claude
Code SDK の調査により 3.1 が技術的に不可能と判定され、3.2（prompt 強化単独で成立）に倒れる
ことが妥当に文書化されている。本リポジトリは unit test フレームワークを持たないため
（CLAUDE.md「テスト・検証」節）、grep ベースの sanity check（NFR 2.1 の 4 キーワード確認）で
代替検証する規約と整合し、missing test には該当しない。

## Reviewed Scope

- Branch: claude/issue-134-impl-feat-developer-taskcreate-taskupdate-tas
- HEAD commit: 34f34870b1853809746c9e7548fb46d6f80f9d8d
- Compared to: main..HEAD
- 変更ファイル: 3 ファイル / +331 行（impl-notes.md 197 行含む）

## AC Coverage

| AC ID | 判定 | 対応位置 |
|---|---|---|
| 1.1 | covered | `.claude/agents/developer.md:150-156` (「tasks.md は当該 Issue における**唯一のタスクリスト**」「複製してはなりません」明記) |
| 1.2 | covered | `.claude/agents/developer.md:161-181` (「限定列挙された」ケースとして明示) |
| 1.3 | covered | `.claude/agents/developer.md:165-181` (1. 緊急 sub-step / 2. 人間からの追加依頼 の 2 ケース具体例) |
| 1.4 | covered | `.claude/agents/developer.md:153-156` (「`tasks.md` に既に対応するタスク行が存在するタスクのために、進捗追跡目的で `TaskCreate` / `TaskUpdate` を呼び出すことは **禁止**」明示) |
| 1.5 | covered | `.claude/agents/developer.md:143-148` (進捗の正本は checkbox、内部 TODO は正本として用いない) |
| 2.1 | covered | `.claude/agents/developer.md:188-189` (反射的 TaskCreate 禁止) |
| 2.2 | covered | `.claude/agents/developer.md:190-192` (進捗追跡手段の変更指示として扱わず checkbox 維持) |
| 2.3 | covered | `.claude/agents/developer.md:193-196` (reminder 受領後の TaskCreate は許容ケース限定) |
| 3.1 | covered | `impl-notes.md:63-78` で Claude CLI / issue-watcher.sh / SDK reminder 出所を調査し、subagent-specific 抑制は技術的に不可能と判定（Req 3.1 の Where 条件不成立） |
| 3.2 | covered | `impl-notes.md:81-83` (Req 3.2 が本ケースに該当、prompt 強化単独で成立) |
| 3.3 | covered | Req 1 / 2 のエージェント定義側規約により単独で成立する状態が維持されている |
| 3.4 | covered | harness 側変更なし（Req 3.2 倒れ）のため適用範囲も Developer 単独で自動的に満たす |
| 4.1 | covered | `impl-notes.md:100-118` (既存 `local-watcher/log/` 配下のログから手動集計可能、本 PR で構造変更なし) |
| 4.2 | covered | `impl-notes.md:43` (10% 以下を達成目標として requirements.md 側で束縛、本 PR は計測手段維持に集中) |
| 4.3 | covered | `impl-notes.md:44` (10% 超過時の追加 Issue 起票は watcher operator 責務として位置付け、impl-notes.md に明示) |
| 4.4 | covered | `impl-notes.md:100-121` (既存ログ構造を維持し手動集計手順を提示、自動ダッシュボードは Out of Scope) |
| 5.1 | covered | `impl-notes.md:125-127` (本 PR merge 後の運用ログで watcher operator が観察。PR 内 e2e は計測不能のため適切な切り分け) |
| 5.2 | covered | `impl-notes.md:127-128` (緊急 sub-step シナリオで許容ケース 1 該当を確認する手順) |
| 5.3 | covered | `impl-notes.md:129-130` (人間追加依頼シナリオで許容ケース 2 該当を確認する手順) |
| 5.4 | covered | `impl-notes.md:131` (10% 超過時の記録・追加調整判断手順) |
| 6.1 | covered | `.claude/agents/developer.md:138-141` (「前節「impl-resume / tasks.md 進捗追跡規約」の…規定を前提として」記述により既存節と矛盾しない設計) |
| 6.2 | covered | Feature Flag Protocol 節は既存節 (root CLAUDE.md / template CLAUDE.md) 共に無変更 |
| 6.3 | covered | `.claude/agents/developer.md:4` および `repo-template/.claude/agents/developer.md:4` の `tools: Read, Write, Edit, Bash, Grep, Glob` 行は無変更 |
| 6.4 | covered | `.claude/agents/developer.md:143-148` が #133 の checkbox 規約を参照しつつ Req 1.5 を再掲（NFR 1.3 が許容する「参照または再掲」） |
| 6.5 | covered | install.sh 無変更のため既存ハイブリッド safe-overwrite 挙動を維持 |
| NFR 1.1 | covered | ears-format / requirements-review-gate / design-review-gate / tasks-generation / feature-flag いずれとも矛盾する記述なし（grep ベース確認） |
| NFR 1.2 | covered | 新規節は言語非依存（特定言語の構文・ライブラリへの依存なし） |
| NFR 1.3 | covered | 新規節は「前節」を参照する形で整合性を取り、Req 1.5 の再掲は NFR 1.3 / Req 6.4 が許容する範囲内 |
| NFR 2.1 | covered | grep 結果で 4 つのキーワード（「TaskCreate / TaskUpdate の使用制限」「許容ケースの限定列挙」「defensive 応答禁止」「進捗の正本は checkbox」）が両ファイルで各 1 件以上ヒット |
| NFR 2.2 | covered | `impl-notes.md:100-121` の手動集計手順は 30 分以内に算出可能な粒度 |
| NFR 3.1 | covered | `.claude/agents/developer.md` (root, self-hosting) と `repo-template/.claude/agents/developer.md` の両方を同期更新済み、次回 cron 実行で本ファイルが Developer subagent prompt として参照される |

## Findings

なし。

## Boundary Check

本 Issue は `needs_architect=false` パスのため `tasks.md` および `design.md` は不在で、
`_Boundary:_` アノテーションも存在しない。実質的な境界は requirements.md の Req 6.3 / 6.5 /
Out of Scope の明示範囲となる。差分ファイルは以下のみで、すべて境界内:

- `.claude/agents/developer.md` (+68 行): Developer エージェント定義への新規節追加。
  Req 6.3 で「tool 一覧変更しない」と明示された frontmatter (L4) は無変更。
- `repo-template/.claude/agents/developer.md` (+66 行): 同等の節を consumer 配布版にも同期。
  Req 6.5 で「install.sh ハイブリッド safe-overwrite 挙動維持」と整合する変更（install.sh
  自体は無変更）。
- `docs/specs/134-feat-developer-taskcreate-taskupdate-tas/impl-notes.md` (新規 +197 行):
  Developer の補足ノート。spec 書き換え (requirements.md / design.md / tasks.md) には該当しない。

requirements.md / 他エージェント定義 / install.sh / labels script / workflow YAML / README いず
れも変更なし。Out of Scope (他エージェント定義への波及 / 自動ダッシュボード / 過去ログ
への遡及計測 / SDK 側機能追加実装 / ハード制限) との整合も確認済み。

## Test Evidence

`CLAUDE.md` の「テスト・検証」節（本リポジトリは unit test フレームワークを持たない）と
整合し、impl-notes.md「静的検証」節 (L169-191) では以下の grep ベース sanity check が記載
されている:

- NFR 2.1 の 4 キーワード grep: 両ファイルで各 4 件ヒットの期待値を提示
  - レビュワーが再実行確認した結果、`.claude/agents/developer.md` で 4 ヒット
    （L134, L143, L161, L183）、`repo-template/.claude/agents/developer.md` で 4 ヒット
    （L124, L133, L149, L171）を確認
- 2 ファイルが共通の規約節を持つ確認 (`grep -c "## TaskCreate / TaskUpdate の使用制限"`):
  期待値 各 1 件

bash / yaml 変更は無いため `shellcheck` / `actionlint` は対象外（impl-notes.md L191）。
Req 5.1〜5.4 の受入確認シナリオは本 PR 内では計測不能（impl-notes.md L92-94 で明示)、
merge 後の Developer 実行ログから watcher operator が手動集計する手順が impl-notes.md
L100-118 に記録されている。これは Req 4.4 / NFR 2.2 が要求する「手動集計可能粒度」と整合し、
本 PR スコープとしては適切な切り分け。

## Feature Flag Protocol 採否確認

- self-hosting 用 `CLAUDE.md` (root): `## Feature Flag Protocol` 節は不在 → opt-out として解釈
- consumer 配布用 `repo-template/CLAUDE.md`: `**採否**: opt-out` を明示

両方とも opt-out のため、flag 観点の追加判定（旧パス温存 / `if (flag)` 分岐 / flag-off
挙動不変 / flag 命名規約）は適用しない（Req 4.2 / NFR 1.1）。

RESULT: approve
