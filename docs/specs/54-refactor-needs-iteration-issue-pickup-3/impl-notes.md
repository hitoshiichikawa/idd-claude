# 実装ノート (#54: refactor needs-iteration Issue pickup 3 層防御)

## 概要

PR #51 / Issue #16 で発生した「PR 専用ラベル `needs-iteration` の Issue 側誤付与により
watcher が impl-resume を起動して既存 PR を force push で壊す」事故を、コード防御 +
ラベル description + README + PjM テンプレの 4 箇所で構造的に止める。

## Commit ↔ 要件 ↔ ファイル対応

| Commit | 主な要件 | 変更ファイル |
|---|---|---|
| `b46b184` fix(watcher): exclude needs-iteration from Issue pickup query | Req 1.1 / 1.2 / 1.3 / 1.4 / 5.2 | `local-watcher/bin/issue-watcher.sh` |
| `b427134` docs(labels): add scope prefix to PR-only / Issue-only label descriptions | Req 2.1 / 2.2 / 2.3 / 2.5 | `.github/scripts/idd-claude-labels.sh` |
| `dbe006f` docs(readme): add scope column to label state transition table | Req 3.1 / 3.2 / 3.3 / 3.4 / NFR 3.1 | `README.md` |
| `3cecd68` docs(claude): guide PR-only iteration label in PjM PR comment | Req 4.1 / 4.2 / 4.3 / 4.4 | `.claude/agents/project-manager.md`, `repo-template/.claude/agents/project-manager.md` |

## 実装上の判断

### Issue 取得クエリは 2 箇所更新

`gh issue list` で Issue を取得するロジックは現コード上 2 箇所:

1. **Dispatcher 本流** (`local-watcher/bin/issue-watcher.sh:2853-2861`): `auto-dev` Issue
   pickup → impl / impl-resume 起動の起点。要件 Req 1.1 の主対象。
2. **Design Review Release Processor** (`local-watcher/bin/issue-watcher.sh:1471-1479`):
   `awaiting-design-review` 付き Issue を対象に、merged design PR 検知 → ラベル除去を
   行う。直接 impl 系は起動しないが、Documentation Set 全体で「`needs-iteration` は
   PR 専用」という主張に整合させるため Req 5.1 の趣旨で同様に除外を追加。

なお `gh pr list` 側（line 404 / 549 / 694）は **PR 検索**であり今回の要件対象外（Issue 誤付与
シナリオが発生し得ない）。

### ラベル description の文字数

要件 Req 2.3（GitHub の 100 字制限）と Open Question を踏まえて prefix 文字を実測した
結果、すべて prefix 込みで 100 字以内に収まり、既存 description の短縮は不要だった:

| ラベル | 旧 | 新 |
|---|---|---|
| auto-dev | `自動開発対象` (6) | `【Issue 用】 自動開発対象` (16) |
| needs-decisions | `人間の判断が必要` (8) | `【Issue 用】 人間の判断が必要` (18) |
| awaiting-design-review | `設計 PR レビュー待ち（Architect 発動時）` (27) | `【Issue 用】 設計 PR レビュー待ち（Architect 発動時）` (37) |
| claude-picked-up | `Claude Code 実行中` (15) | `【Issue 用】 Claude Code 実行中` (25) |
| ready-for-review | `PR 作成完了` (7) | `【Issue 用】 PR 作成完了` (17) |
| claude-failed | `自動実行が失敗` (7) | `【Issue 用】 自動実行が失敗` (17) |
| skip-triage | `Triage をスキップ` (12) | `【Issue 用】 Triage をスキップ` (22) |
| needs-rebase | `approved PR で base が古い／conflict が発生済み（Phase A: Merge Queue Processor が付与）` (73) | `【PR 用】 approved PR で base が古い／conflict が発生済み（Phase A: Merge Queue Processor が付与）` (80, **最長**) |
| needs-iteration | `PR レビューコメントの反復対応待ち（#26 PR Iteration Processor が処理）` (50) | `【PR 用】 PR レビューコメントの反復対応待ち（#26 PR Iteration Processor が処理）` (57) |

最長は `needs-rebase` の 80 文字で、100 字制限内に余裕あり。

### Issue / PR の prefix 表記

「【Issue 用】」（9 文字）「【PR 用】」（6 文字）の括弧スタイルを採用。理由:

- 一目で適用先が読める（GitHub のラベル一覧画面で description の先頭が viewport に入る）
- 「【】」は GitHub Markdown では特別扱いされず、URL エスケープも不要
- 「[PR-only]」等の英語短縮は誤読リスクと文化差があるため避けた

### PjM template の implementation モード PR 案内コメント拡張

`repo-template/.claude/agents/project-manager.md` の implementation モードでは元々
「Issue へコメントで実装 PR リンクを投稿」という 1 行のみで、具体的な文面が無かった。
Req 4.2 で文言追加が必要なため、quote ブロック形式に拡張:

```
> 🚀 実装 PR を作成しました: #<impl-pr-number>
>
> - レビューを開始してください。問題なければ merge してください
> - レビュー反復を回す場合は **この PR に** `needs-iteration` ラベルを付与してください...
```

Req 4.4 (既存項目を削除しない) は満たす（テンプレ全体を保ち、追記のみ）。

### 「Issue へ誤付与すると watcher が当該 Issue の pickup を抑止します」を併記

エンドユーザー観点で「もし誤って Issue に付けたらどう挙動するか」が明示されると、誤操作後に
人間が「あれ、watcher が動いていない」と気づく手がかりになる。Req 1.2 の挙動とテンプレ文言の
セルフ整合性を強化する目的で併記した。

## 受入基準達成確認

| 要件 ID | 達成内容 | 検証手段 |
|---|---|---|
| Req 1.1 | Issue 取得 server-side query に `-label:"$LABEL_NEEDS_ITERATION"` 追加 | `local-watcher/bin/issue-watcher.sh:2861` (dispatcher 本流) / `:1476` (DRR) |
| Req 1.2 | 除外時は既存「処理対象の Issue なし」ログを維持（追加エラー無し） | dry run 実行で `処理対象の Issue なし` を確認（実環境結果は本ノート末尾の検証結果参照） |
| Req 1.3 | 既存除外ラベル群のロジックは変更せず、追加除外として 1 ラベル増えるのみ | クエリ文字列の前後比較（既存 5 ラベルに 1 つ append） |
| Req 1.4 | server-side filter が `needs-iteration` 無しなら通過 → 次サイクルで通常評価 | GitHub Search 仕様により、`-label:foo` は label foo を持たない Issue を返す（人間がラベルを除去すれば次サイクルで pickup 候補に戻る） |
| Req 2.1 / 2.2 | LABELS 配列 9 件すべてに `【PR 用】`/`【Issue 用】` prefix 付与 | `.github/scripts/idd-claude-labels.sh:65-73` |
| Req 2.3 | 全 description が 100 字以内 (実測: 最長 80 字) | impl-notes 上の文字数表 |
| Req 2.4 | `--force` 経路で description 更新が反映される（既存ロジック保持） | `idd-claude-labels.sh:107-114` の `gh label create --force` 既存パス |
| Req 2.5 | name / color は変更せず | LABELS 配列の name / color フィールド diff = 0 |
| Req 3.1 / 3.2 / 3.3 | README ラベル状態遷移まとめ表に「適用先」列を追加し、9 ラベル全てに Issue / PR を明記 | `README.md:524-538` |
| Req 3.4 | 既存「意味」「付与主」列を保持（列追加のみ） | diff で「意味」「付与主」列の値が変化していないこと |
| Req 4.1 / 4.2 | design-review / implementation 両モードの Issue コメントに「PR に付ける」旨の 1 行追加 | `.claude/agents/project-manager.md:36`, `:100` |
| Req 4.3 | root と repo-template 両方に同等記載 | `repo-template/.claude/agents/project-manager.md:37`, `:117` |
| Req 4.4 | 既存案内（merge / やり直し / `awaiting-design-review`）を保持 | diff は追記のみで既存行は変更されない |
| Req 5.1 | コード防御・ラベル description・README・PjM テンプレの 4 箇所すべてで「needs-iteration は PR 適用」と一貫表記 | 各ファイルでの `needs-iteration` 関連文言は「PR 用 / PR 適用 / この PR に / Issue ではなく PR に」で統一 |
| Req 5.2 | 誤付与 Issue が impl 系起動の対象にならない | dispatcher 本流クエリでの除外（Req 1.1 と同根拠） |
| NFR 1.1 / 1.2 / 1.3 | 既存 env var 名 / cron / ラベル遷移契約を変更せず | LABEL_NEEDS_ITERATION 既存定数を流用、cron 起動文字列に影響無し |
| NFR 1.4 | ラベル name / color 不変、`--force` 無し時の上書き挙動も既存通り | LABELS 配列の `name|color` 部 diff = 0 |
| NFR 1.5 | PjM テンプレの fixed phrase / 構造を保持 | 既存 quote ブロック構造を保ち、新 bullet を中段に挿入のみ |
| NFR 2.1 | shellcheck で **新規警告ゼロ** | 変更前後で警告数 46 行 → 46 行（pre-existing info のみ。私の編集による新規警告 0 件） |
| NFR 3.1 | README のポーリングクエリ例に `-label:needs-iteration` を追加し、watcher の実クエリと整合 | `README.md:548` |
| NFR 4.1 | 手動スモーク手順を PR 本文 Test plan に書く（PjM の責務） | 本 impl-notes の検証結果と、PR 本文の Test plan で人間に dogfood 検証を依頼 |

## 検証結果

### Static analysis

```
$ shellcheck local-watcher/bin/issue-watcher.sh .github/scripts/idd-claude-labels.sh
exit 0
```

注: `issue-watcher.sh` には変更前から SC2317 (info: indirect call false positive) と
SC2012 (info: ls vs find) が pre-existing で出ているが、本変更で**新規警告は増えていない**
（変更前後の警告行数が同一）。

```
$ bash -n local-watcher/bin/issue-watcher.sh && echo "syntax OK"
syntax OK
$ bash -n .github/scripts/idd-claude-labels.sh && echo "syntax OK"
syntax OK
```

### Watcher dry run（対象なしシナリオ）

```
$ REPO=hitoshiichikawa/idd-claude REPO_DIR=/tmp/idd-watcher-dryrun-54 \
    LOCK_FILE=/tmp/idd-watcher-dryrun-54.lock \
    LOG_DIR=/tmp/idd-watcher-dryrun-54-logs \
    bash local-watcher/bin/issue-watcher.sh
...
[2026-04-28 21:59:45] design-review-release: サイクル開始 ...
[2026-04-28 21:59:46] design-review-release: 対象候補 1 件、処理対象 1 件、overflow=0
[2026-04-28 21:59:47] design-review-release: Issue #55: merged-design-pr=none, action=kept
[2026-04-28 21:59:47] 処理対象の Issue なし
[2026-04-28 21:59:47] 完了
```

正常終了 + 「処理対象の Issue なし」を出力 (Req 1.2)。

### クエリ文字列の目視確認

GitHub Search 仕様で server-side フィルタが正しく構築されることを実 API で確認:

```
$ gh issue list --repo hitoshiichikawa/idd-claude --label auto-dev --state open \
    --search '-label:"needs-decisions" -label:"awaiting-design-review" -label:"claude-picked-up" -label:"ready-for-review" -label:"claude-failed" -label:"needs-iteration"' \
    --json number,title,labels --limit 5
[]
```

クエリは GitHub 側で受理され、構文エラーは無い。

### 検証できなかった項目（PR の Test plan で人間に依頼）

- **誤付与シナリオの完全 E2E スモーク**: 本物の Issue に `auto-dev` + `needs-iteration` を
  併存させて watcher を 1 サイクル走らせ、当該 Issue が pickup されないことの確認は、
  ラベル誤付与による副作用を伴うため本実装では行わず、PR レビュー時に人間がローカル / dogfood
  環境で確認することを推奨（NFR 4.1 のテスト手順を PR 本文に明記）。
- **`idd-claude-labels.sh --force` の実行**: GitHub 側のラベル description が即座に書き
  換わってしまうため本実装では実行せず、構文・shellcheck 確認のみ。`--force` 実行は人間の
  判断で別フェーズに委ねる。

## 派生タスク候補（次の Issue 起票候補）

- 既存の誤付与履歴（Issue 側に `needs-iteration` が残っている可能性）の棚卸し: 本実装では
  自動マイグレーションを行わない（Out of Scope）。`gh issue list --label needs-iteration` で
  人間が手動チェックすることが想定される。
- ラベル description 上限が将来 GitHub 側で拡張された場合の prefix 表記の見直し（現状は
  100 字 / `【PR 用】` 6 字 / `【Issue 用】` 9 字で十分余裕あり）。

## 確認事項（PR レビュワーへ）

- `repo-template/.claude/agents/project-manager.md` の design-review モードには既に
  `PR_ITERATION_DESIGN_ENABLED=true` 有効時の `needs-iteration` 案内が存在する。本要件
  Req 4.1 の文言を **既存案内行の直後**に「⚠ ... Issue ではなく PR に」のガード行として
  追加した。冗長か / 統合した方が良いかは PjM 文面の好みに依存するためレビュー時にご判断
  ください。
- root (`.claude/agents/project-manager.md`) には PR_ITERATION_DESIGN_ENABLED 案内が
  なく、シンプルな 1 行追加にしている。design-review-release 機能は repo-template 側の
  ターゲット運用としての文脈なので意図的に root では省略しているが、揃えた方が良ければ次の
  Issue で追従可能。
