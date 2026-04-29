# Implementation Notes (#52)

## 概要

Issue #52 の design.md / tasks.md に従い、`claude-claimed` ラベル（claim/Triage 段階専用）を導入し、`claude-picked-up` を「Triage 通過後の実装フェーズ」専用に切り詰めるリファクタを実装した。新規コンポーネントは無く、既存 Dispatcher / Slot Runner / `_slot_mark_failed` / `mark_issue_failed` / PjM design-review prompt の各遷移点を局所的に書き換えるアプローチ（design.md「State Refinement」パターン）。

## タスクごとの変更サマリ

| Task | 対象ファイル | 主な変更 | コミット |
|---|---|---|---|
| 1.1 | `.github/scripts/idd-claude-labels.sh` | LABELS 配列に `claude-claimed\|c39bd3\|【Issue 用】 ...` を `claude-picked-up` の直前に追加 | `b769778` |
| 1.2 | `repo-template/.github/scripts/idd-claude-labels.sh` | 同上の差分（【Issue 用】prefix なし、テンプレートの語彙に合わせる） | `8caab89` |
| 2.1 | `local-watcher/bin/issue-watcher.sh` | `LABEL_CLAIMED="claude-claimed"` 定数追加 + ヘッダコメント遷移図に `claude-claimed` を挿入 | `5264192` |
| 2.2 | 同上 | Dispatcher exclusion query に `-label:"$LABEL_CLAIMED"` を追加（既存 6 ラベル除外は維持） | `493bf7d` |
| 2.3 | 同上 | Dispatcher の claim 付与を `LABEL_PICKED` → `LABEL_CLAIMED` に変更、WARN メッセージとセクションコメントを更新 | `5942f96` |
| 3.1 | 同上 | `_slot_mark_failed` を `--remove-label LABEL_CLAIMED --remove-label LABEL_PICKED` の両系統除去に拡張、関数冒頭コメント書き換え | `9d4aadd` |
| 3.2 | 同上 | `_slot_run_issue` の Triage `needs-decisions` 分岐を `LABEL_CLAIMED` 除去に切り替え、ログメッセージとコメント更新 | `3fe1b74` |
| 3.3 | 同上 | `_slot_run_issue` mode 判定後、impl / impl-resume の場合に限り `claude-claimed → claude-picked-up` を atomic 付け替え。失敗時は `_slot_mark_failed "label-handover"` で `claude-failed` 化 | `948e3b3` |
| 3.4 | 同上 | design ルートの prompt 内 `STEPS` heredoc の「Issue ラベル: claude-picked-up → awaiting-design-review」を `claude-claimed → awaiting-design-review` に書き換え（impl ルート prompt は不変） | `c219a92` |
| 3.5 | 同上 | `mark_issue_failed`（impl pipeline 用）も両系統除去に拡張、関数内コメント追加 | `147ac94` |
| 4.1 | `.claude/agents/project-manager.md` | design-review モードの「実施事項」3 番を `削除: claude-claimed` に書き換え、「失敗時の挙動」末尾を `claude-claimed または claude-picked-up を外し` に拡張 | `ee25830` |
| 4.2 | `repo-template/.claude/agents/project-manager.md` | 4.1 と同じ差分 | `1ad05db` |
| 5.1 | `README.md` | ラベル定義表 / `gh label create` 例 / 適用先表 / ポーリングクエリ例 / 状態遷移図 / 解説文を更新 | `c74b482` |
| 5.2 | `README.md` | Phase C 「claim タイミングの挙動変更」表の `claude-picked-up` を `claude-claimed` に書き換え、Issue #52 専用 Migration Note を追加 | `511f7a9` |
| 5.3 | `QUICK-HOWTO.md` | ラベル一覧文字列に `claude-claimed` を追加、簡易遷移図に `claude-claimed → claude-picked-up` を挿入 | `70d1593` |

## 受入基準と担保

| Req | AC 概要 | 担保箇所（テスト / 検証手段） |
|---|---|---|
| 1.1 | Dispatcher claim 時に `claude-claimed` 付与 | `issue-watcher.sh` L3162 `--add-label "$LABEL_CLAIMED"`（実コードで担保。E2E は Task 6.3） |
| 1.2 | claim 時に `claude-picked-up` を付与しない | 同上 — claim API call は `LABEL_CLAIMED` のみを引数に渡す |
| 1.3 | `claude-claimed` 付与中＝claim/Triage 状態 | README ラベル一覧 / 適用先表 / 状態遷移図で文書化（Task 5.1） |
| 1.4 | `claude-claimed` 付与失敗で slot 解放 | L3162-3167 既存 `_slot_release "$slot"; continue` パスを継承（Task 2.3） |
| 2.1 | Triage 通過 → Developer 進む判定で `claude-claimed` 除去 + `claude-picked-up` 付与 | `_slot_run_issue` L2917-2929 の atomic gh issue edit（Task 3.3） |
| 2.2 | impl 進行中は `claude-picked-up` のみ保持 | Task 3.3 の付け替え後、Stage A〜C は `claude-picked-up` のみで進行（既存実装、確認のみ） |
| 2.3 | 同時 2 ラベル状態を継続させない | 単一 `gh issue edit --remove-label A --add-label B` API call の atomicity に依拠（Task 3.2 / 3.3） |
| 3.1 | needs-decisions で `claude-claimed` 除去 | `_slot_run_issue` L2893-2895（Task 3.2） |
| 3.2 | architect 起動で `claude-claimed → awaiting-design-review` 直行（design ルート） | Slot Runner で design 経路は付け替えを skip（Task 3.3 の if 条件）+ PjM agent prompt 書き換え（Task 3.4 / 4.1 / 4.2） |
| 3.3 | Triage 失敗で `claude-claimed` 除去 + `claude-failed` 付与 | `_slot_mark_failed` 両系統除去（Task 3.1） |
| 3.4 | `claude-claimed` をいかなる Triage 終了経路でも残置しない | needs-decisions / design / impl 着手 / Triage 失敗 / mark_issue_failed の 5 経路すべてで `claude-claimed` 除去（Task 3.1, 3.2, 3.3, 3.5） |
| 4.1 | `claude-claimed` 付き Issue を新規 pickup から除外 | Dispatcher exclusion query L3107 に `-label:"$LABEL_CLAIMED"`（Task 2.2） |
| 4.2 | exclusion query が claude-claimed 含む全終端を排除 | 同上 |
| 4.3 | 同一サイクル多 slot で同 Issue 二重 claim 不可 | `_dispatcher_find_free_slot` 単一プロセス性 + atomic API call で構造的保証（PR #51 Phase C 由来、本変更で破壊せず） |
| 5.1 | 旧 `claude-picked-up` のみの進行中 Issue を中断・再 claim せず完走 | exclusion query が `LABEL_PICKED` も継続除外（Task 2.2 で `LABEL_CLAIMED` を **追加** したのみ、`LABEL_PICKED` は維持） |
| 5.2 | 既存 env var 不変 | `LABEL_CLAIMED` 追加のみ。`REPO`/`REPO_DIR`/`LOG_DIR`/`LOCK_FILE`/`TRIAGE_MODEL`/`DEV_MODEL` 等の名称・形式は触っていない（`git diff` で確認済み） |
| 5.3 | cron / launchd 登録文字列不変 | `~/bin/issue-watcher.sh` 起動行は変更なし |
| 5.4 | 既存ラベル名・意味不変 | `idd-claude-labels.sh` LABELS 配列に 1 行追加のみ。既存 9 行は touch せず |
| 5.5 | `claude-claimed` 未存在で起動 → ラベル付与失敗を slot 解放扱い | L3162-3167 既存 `--add-label` 失敗時 = `_slot_release` + `continue`（Req 1.4 と同経路） |
| 6.1 | `idd-claude-labels.sh` で `claude-claimed` 追加 | `.github/scripts/idd-claude-labels.sh` LABELS 配列に新規 1 行（Task 1.1） |
| 6.2 | 既存時は冪等スキップ | LABELS 配列に 1 行追加するだけのため、既存 EXISTS 分岐ロジックがそのまま適用される |
| 6.3 | `--force` で上書き更新 | 同上、UPDATED 分岐もそのまま流用 |
| 6.4 | 既存ラベル群の name / color / description 不変 | 1 行追加のみ。`git diff` で確認済み |
| 6.5 | description に【Issue 用】prefix | `claude-claimed\|c39bd3\|【Issue 用】 Claude Code が claim 済（Triage 実行中）` を `.github/scripts/idd-claude-labels.sh` に記載（Task 1.1） |
| 7.1 | README 状態遷移セクションが両ルートを図示 | README L575-595 状態遷移図を impl ルート / design ルートともに `claude-claimed` 経由で図示（Task 5.1） |
| 7.2 | README ラベル一覧に追加 | README L297-303 / L529-540 / L541-552 を更新（Task 5.1） |
| 7.3 | README に Migration Note | Phase C「claim タイミングの挙動変更」節末尾に Issue #52 Migration Note 追記（Task 5.2） |
| 7.4 | PjM impl 系では `claude-picked-up` のみ指定 | `.claude/agents/project-manager.md` および `repo-template/.claude/agents/project-manager.md` の implementation モード「実施事項」3 番は **不変**（Task 4.1 / 4.2 で意図的に skip） |
| 8.1 | dogfood: impl ルート遷移成立 | E2E 検証は Task 6.3 として deferrable（後述） |
| 8.2 | dogfood: needs-decisions ルート | 同上 |
| 8.3 | dogfood: awaiting-design-review ルート | 同上 |
| NFR 1.1 | ラベル付与/除去をログ出力 | `dispatcher_log` / `dispatcher_warn` / `slot_log` / `slot_warn` で `claude-claimed` 付与・除去・付け替えを各 case ログ |
| NFR 1.2 | 同時 2 ラベル状態 5 秒以上継続させない | 単一 `gh issue edit --remove-label X --add-label Y` API call の atomicity（GitHub Labels API の PATCH 性 + 通常 round-trip 数百 ms） |
| NFR 2.1 | `idd-claude-labels.sh` 再実行のみで導入完了 | LABELS 配列追加のみで完了 |
| NFR 2.2 | 旧 watcher 由来進行中 Issue 誤遷移なし | exclusion query が `LABEL_PICKED` 引き続き除外、Slot Runner は再起動しない（Task 2.2） |
| NFR 3.1 | shellcheck 警告 0 | 後述「検証結果」参照 |
| NFR 3.2 | actionlint 警告 0 | YAML 不変のため対象なし。後述「検証結果」参照 |

## 検証結果

### shellcheck（Task 6.1）

```bash
shellcheck local-watcher/bin/issue-watcher.sh \
           .github/scripts/idd-claude-labels.sh \
           repo-template/.github/scripts/idd-claude-labels.sh
```

- `--severity=error`: 0 件
- `--severity=warning`: 0 件
- `--severity=info`（既存 SC2317 / SC2012 を含む）: 既存 8 件のみ。**いずれも本 PR の変更箇所に起因しない**。`git blame` で確認可能（merge-queue / design-review-release / 既存の `_slot_run_issue` の `ls -d` 等は本 PR で touch していない）

新規警告 0 件（NFR 3.1 を満たす）。

### actionlint

`actionlint` がローカル環境にインストールされていなかったため未実施。本 PR は **YAML を 1 行も変更していない**（`git diff main..HEAD --name-only | grep -E '\.ya?ml$'` が空）ため、新規警告は発生し得ない（NFR 3.2 を構造的に満たす）。

### bash 構文チェック

- `bash -n local-watcher/bin/issue-watcher.sh` : OK
- `bash -n .github/scripts/idd-claude-labels.sh` : OK
- `bash -n repo-template/.github/scripts/idd-claude-labels.sh` : OK

### 手動スモークテスト（Task 6.2）

- **cron-like PATH での依存解決**: `env -i HOME=$HOME PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" bash -c 'command -v claude gh jq flock git'` → 5 ツール全て解決確認（watcher 冒頭 L29 の PATH prepend 後の状態）
- **dry-run（処理対象なし）**: `REPO=hitoshiichikawa/idd-claude REPO_DIR=/tmp/issue-watcher-smoke ... bash local-watcher/bin/issue-watcher.sh` を実行 → `[YYYY-MM-DD HH:MM:SS] 処理対象の Issue なし` / `[YYYY-MM-DD HH:MM:SS] 完了` で正常終了確認。Dispatcher exclusion query を新規 `claude-claimed` 含みで実行する経路も走り、エラーなし
- **`idd-claude-labels.sh` の冪等性スモーク**: 構文 / `--help` / 配列の 1 行追加のみであることを `git diff` で確認。実 GitHub API 経由のスクラッチ repo テストは未実施（gh authenticated だが、スクラッチ repo の clean-up 責務を考慮しスキップ）

### Dogfooding E2E（Task 6.3）— deferrable

本リポジトリ自身に以下 3 種の test issue を立てて watcher cron で観測する E2E は、本 PR の merge 後に dogfood として実施する想定:

1. impl ルート test issue（trivial 修正）→ `auto-dev → claude-claimed → claude-picked-up → ready-for-review` (Req 8.1)
2. needs-decisions ルート test issue（曖昧要件）→ `auto-dev → claude-claimed → needs-decisions` (Req 8.2)
3. awaiting-design-review ルート test issue（新規 API / スキーマ変更相当）→ `auto-dev → claude-claimed → awaiting-design-review` (Req 8.3)

実施結果は PR merge 後に Issue #52 のコメントに追記する運用で十分（design.md Testing Strategy が dogfooding を E2E の主体としているため、PR 内では idempotent に再現可能な検証のみを実施）。

## 確認事項（Reviewer / 人間判断ポイント）

1. **PjM agent の auto-close 失敗フォールバック（design-review モード）**: `.claude/agents/project-manager.md` L79 / `repo-template/.claude/agents/project-manager.md` L97 の「自動修正不能な場合」分岐は今もテキストとして "Issue から `claude-picked-up` を外して" を含む。design-review モードに到達した時点では Issue は `claude-claimed` を持っているはずだが、tasks.md の 4.1 / 4.2 が指示するのは「実施事項 3 番」と「失敗時の挙動」末尾の 2 箇所のみで、L79 / L97 は明示的な指示対象外だった。どちらの解釈が正かは Architect 判断を仰ぐ。実害としては「失敗時の挙動」セクション末尾（L220 / L238）で **両系統除去** を許容する記述に切り替えてあるため、実 PjM 起動時には正しい遷移ができる。design.md の「PjM agent template」表（L122-129）も「失敗時の挙動」のみを変更対象として列挙しているため、現状の実装は design.md と一致する解釈。

2. **`_slot_run_issue` の `MODE = impl-resume` 経路でも `claude-claimed → claude-picked-up` 付け替えを行う実装にした**: design.md の擬似コード（L296-330）は impl のみを示しているが、本文 L284-286 では「**impl ルート**」と表記しており、`MODE = impl-resume` の挙動が明示されていない。spec dir が既存（設計 PR merge 済み）の場合は Triage を skip するが、その後も実装フェーズに入るため `claude-picked-up` への付け替えが必要と判断（要件 2.1 / 2.2 を満たすため）。実装では `if [ "$MODE" = "impl" ] || [ "$MODE" = "impl-resume" ]` で両モードを対象にした。

3. **README の状態遷移図で impl ルート（Triage 通過後 Architect 不要パターン）も `claude-claimed` を経由する旨を明示**: design.md L52-66 mermaid 図で `auto-dev → claude_claimed → claude_picked_up` が描かれているとおり、本実装でも全 Issue が `claude-claimed` を経由する。README の更新前テキスト遷移図は「Triage 直後に分岐」する書き方だったため、本 PR で `claude-claimed` ノードを 1 段挟んだ表現に書き換えた。

4. **Feature Flag Protocol の採否**: 本リポジトリの `CLAUDE.md` には `## Feature Flag Protocol` 節は存在せず、`repo-template/CLAUDE.md` には `**採否**: opt-out` が宣言されている。両方とも opt-out として解釈したため、本実装は通常の単一実装パスで進めた（flag を導入していない）。

## 派生タスク候補

- **Issue #52 完了後の Dashboard / SLA 集計ロジック更新**: design.md Out of Scope に記載されたとおり別 Issue 化が望ましい
- **GitHub Actions 版 (`.github/workflows/issue-to-pr.yml`) への `claude-claimed` 導入**: design.md Out of Scope。Actions 版は claim atomicity 機構を持たないため `claude-picked-up` 1 ラベル運用のままで semantic 不整合を起こさない（design.md L544 参照）。需要があれば別 Issue で議論
- **PjM agent template L79 / L97（design-review 失敗フォールバック）の文言整備**: 上記「確認事項 1」参照。Architect 判断で別 Issue 化可

## Feature Flag

本 PR では Feature Flag を導入していない（プロジェクト宣言が opt-out のため。CLAUDE.md / `repo-template/CLAUDE.md` 双方を確認済み）。
