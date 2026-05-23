# 実装ノート (#169)

## 概要

Quota-Aware Watcher (#66) の reset 予定時刻永続化先を、Issue body の hidden marker
（`gh issue view` → marker 編集 → `gh issue edit --body` の read-modify-write）から、
repo slug 単位で分離済みの `LOG_DIR` 配下のローカルファイルへ移行した。これにより、人間が
GitHub UI で同 Issue 本文を編集した場合に watcher の永続化処理がそれを上書きする lost
update を根本解消した。読取側はローカルファイルを優先しつつ、移行期に旧 marker しか持たない
Issue が取り残されないよう本文 marker のフォールバック読取を維持する。

design.md / tasks.md は本 spec に存在せず（`requirements.md` のみ確定）、requirements.md の
AC を直接実装方針に落とした。

## 採用したファイルフォーマット

- **永続化先**: `$LOG_DIR/quota-reset-times.json`（既定。`QUOTA_RESET_STATE_FILE` env で上書き可）
  - `LOG_DIR` は `$HOME/.issue-watcher/logs/<repo_slug>`（既存定義、line 336）。repo slug 単位で
    分離済みのため異なる repo の値は混在しない（Req 1.4）
- **JSON 形状**: `{ "<issue_number>": <reset_epoch_int>, ... }`
  - Issue 番号を文字列キー、reset epoch を整数値として保持（Req 2.1）
  - 1 Issue につき key 1 個（upsert で最新値に収束 / Req 2.3, NFR 4.1）
- **書込**: `jq '. + {($num): $epoch}'` で既存 object に upsert → `mktemp` で同一ディレクトリに
  temp file 出力 → `mv -f` でアトミック置換（破損リスク低減）
- **新規 env var**: `QUOTA_RESET_STATE_FILE`（永続化先パス上書き用。既定値あり = 後方互換）。
  既存 env var（`QUOTA_AWARE_ENABLED` / `QUOTA_RESUME_GRACE_SEC`）の名前・受理形式・既定値は不変。

## 関数の変更点

- `qa_persist_reset_time`（書込側）
  - `gh issue view` / `gh issue edit --body` を完全に廃止（Req 1.2, 1.3）
  - 不正な epoch（非数値）は書き込まず return 1
  - `mkdir -p` で永続化ディレクトリ確保（防御的。通常は line 507 で作成済み）
  - 既存ファイルを `jq -e` で読み、破損していれば空 object から初期化して書込を続行
  - return 契約は不変: 0=persisted / 1=failure（warn only、呼び出し元を fail させない / Req 4.1, 4.2, NFR 1.4）
- `qa_load_reset_time`（読取側）
  - ローカルファイル優先（`jq -er '.[$num] | select(type=="number") | floor | tostring'` / Req 3.1, 3.3）
  - ローカルに有効値が無ければ Issue body の旧 marker をフォールバック読取（Req 3.2, 3.4）
  - 破損ファイル / 不正値 / 双方不在は数値以外を返さず stdout 空 + return 1（Req 4.4, 4.5, NFR 1.4）
  - return 契約は不変: 0=found（epoch を stdout）/ 1=absent or malformed
- `qa_build_escalation_comment`（Req 5）
  - 「当該 Issue body の `<!-- idd-claude:quota-reset:...:v1 -->` 行を削除した上で…」という
    本文 marker 削除手順を除去し、`needs-quota-wait` → `claude-failed` 付け替えのみ案内する文面に修正
  - 検知 Stage / reset epoch / ISO 8601 / grace の明記は従来どおり維持（Req 5.3）
- `qa_handle_quota_exceeded`（NFR 2.1, 2.2）
  - 永続化成功時に `reset persisted issue=#N stage=... reset_epoch=... file=...` をログ出力
  - 失敗 warn 行にも reset_epoch を追加し grep 可能性を強化
- セクションヘッダコメント（line 555 付近）の永続化方式説明を新方式に更新

## 後方互換の根拠（NFR 1）

- env var 名・受理形式・既定値（`QUOTA_AWARE_ENABLED=true` / `QUOTA_RESUME_GRACE_SEC=60`）不変（NFR 1.1）
- `QUOTA_AWARE_ENABLED=false` 時の gate 早期 return 経路は未変更（NFR 1.2）
- ラベル付与/除去タイミング・`claude-failed` 非同時付与の契約は未変更（NFR 1.3）
- 読取（0=found / 1=absent or malformed）・書込（0=persisted / 1=failure, warn only）の
  return 契約は維持（NFR 1.4）
- 旧 marker を持つ既存 `needs-quota-wait` Issue はフォールバック読取で従来どおり自動 resume 可能
- 新規 env `QUOTA_RESET_STATE_FILE` は既定値ありで未設定環境は従来パスに帰着

## スモークテスト結果

一時 `LOG_DIR` + `gh` モック（本文を返す関数）で `qa_persist_reset_time` /
`qa_load_reset_time` を抽出評価して検証。全 12 ケース PASS:

| # | 検証内容 | 対応 AC | 結果 |
|---|---|---|---|
| 1 | persist 成功時 return 0 | 4.1 | PASS |
| 2 | 書込→読取で同一 epoch 返却 | 1.1, 3.1, 4.3 | PASS |
| 3 | persist がローカルファイルへ書込（body 経由でない） | 1.1, 1.2, 1.3 | PASS |
| 4 | 複数 Issue を番号で区別 | 2.1, 2.2 | PASS |
| 5 | 同一 Issue 上書きで 1 件に収束（冪等） | 2.3, NFR 4.1 | PASS |
| 6 | ローカル不在時に本文 marker フォールバック | 3.2, 3.4 | PASS |
| 7 | ローカル優先（両方ある場合） | 3.3 | PASS |
| 8 | 破損ファイルで return 1 / stdout 空 | 4.5 | PASS |
| 9 | 双方不在で return 1 / stdout 空 | 4.4 | PASS |
| 10 | 不正 epoch 書込で return 1 | 4.1（malformed 非書込） | PASS |
| 11 | ファイル内文字列値で当該 Issue return 1 | 4.5 | PASS |
| 12 | 不正値 sibling があっても有効値は読める | 4.3, 4.5 | PASS |

```
PASS=12 FAIL=0
```

### shellcheck（NFR 3）

`shellcheck local-watcher/bin/issue-watcher.sh` の警告件数を main と比較:

- main: 29 件（既存 SC2317 info 等）
- 本ブランチ: 29 件

→ **本変更による新規警告 0 件**（NFR 3.1 充足）。

## 受入基準 → テスト対応表

| AC | 担保 |
|---|---|
| 1.1 | スモーク #2, #3（ローカルファイルへ書込み） |
| 1.2 / 1.3 | 実装上 `gh issue view/edit` 呼出を qa_persist_reset_time から除去（スモーク #3 で body 非依存を傍証） |
| 1.4 | `LOG_DIR`（repo slug 分離）配下に配置。コードレビューで担保 |
| 2.1 / 2.2 | スモーク #4 |
| 2.3 | スモーク #5 |
| 3.1 / 3.3 | スモーク #2, #7 |
| 3.2 / 3.4 | スモーク #6 |
| 4.1 | スモーク #1, #10 |
| 4.2 | 実装上 return 1 を warn 吸収（qa_handle_quota_exceeded 側は継続 / コードレビュー） |
| 4.3 | スモーク #2, #12 |
| 4.4 | スモーク #9 |
| 4.5 | スモーク #8, #11 |
| 4.6 | `process_quota_resume` の `continue`（ラベル維持）は未変更。read 1 で除去しない（コードレビュー） |
| 5.1 / 5.2 | escalation コメントから body marker 削除手順を除去（diff レビュー） |
| 5.3 | escalation コメントの Stage / epoch / ISO 8601 明記は未変更 |
| 6.1 / 6.2 / 6.3 | README の永続化方式・escalation 例・フォールバック読取記述を更新 |
| NFR 1.1〜1.4 | env / exit code / ラベル契約 / return 契約 不変（後方互換の根拠 参照） |
| NFR 2.1 / 2.2 | qa_handle_quota_exceeded のログ追加 + process_quota_resume 既存ログ |
| NFR 3.1 | shellcheck 新規警告 0 件 |
| NFR 4.1 | スモーク #5 |

## 確認事項

- なし。requirements.md の AC・Out of Scope に矛盾は見当たらず、設計上の判断（永続化先
  ファイル名 `quota-reset-times.json` / Issue 番号 keyed JSON / アトミック書込）はタスク指示の
  「設計上の要点」に沿って確定した。`QUOTA_RESET_STATE_FILE` env var は override 用に追加した
  もので、既定値があるため後方互換性に影響しない。
- 派生タスクの提案: 旧 Issue body 残存 marker のクリーンアップは Out of Scope（読取フォールバック
  として残置）。将来、移行完了後にフォールバック読取と残存 marker を撤去する cleanup Issue を
  起票する余地はあるが、本変更の必須要件ではない。

STATUS: complete
