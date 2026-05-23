# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-169-impl-bug-watcher-qa-persist-reset-time-issue
- HEAD commit: 8a2ef23（実装本体: cac8aa0）
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため **opt-out**。
  通常の 3 カテゴリ判定のみ実施（flag 観点は適用しない）

## Verified Requirements

- 1.1 — `qa_persist_reset_time` が `$QUOTA_RESET_STATE_FILE`（既定 `$LOG_DIR/quota-reset-times.json`）へ書込（issue-watcher.sh:785-826）/ smoke #2,#3
- 1.2 / 1.3 — `qa_persist_reset_time` から `gh issue view` / `gh issue edit --body` を完全除去。body の read-modify-write を廃止（diff line 785-826。`gh issue edit --body` は line 780 のコメント内「行わない」記述のみ残存）
- 1.4 — `LOG_DIR`（`$HOME/.issue-watcher/logs/<repo_slug>`、repo slug 分離済み）配下に配置。他 repo の値は混在しない（issue-watcher.sh:776）
- 2.1 / 2.2 — Issue 番号を文字列キーとする JSON `{ "<num>": <epoch> }`。読取は `.[$num]` で当該 Issue のみ取得（issue-watcher.sh:846-848）/ smoke #4
- 2.3 — `jq '. + {($num): $epoch}'` の upsert で 1 Issue 最新値 1 件に収束（issue-watcher.sh:818-821）/ smoke #5
- 3.1 / 3.3 — `qa_load_reset_time` がローカルファイルを先に参照し、有効値があれば即 return（body marker より優先）（issue-watcher.sh:844-853）/ smoke #2,#7
- 3.2 / 3.4 — ローカルに有効値が無い場合のみ body の `<!-- idd-claude:quota-reset:<epoch>:v1 -->` をフォールバック読取（issue-watcher.sh:855-868）/ smoke #6
- 4.1 — 書込成功で return 0、不正 epoch / mkdir / mktemp / jq / mv 失敗で return 1（issue-watcher.sh:789-825）/ smoke #1,#10
- 4.2 — `qa_handle_quota_exceeded` は persist 失敗を warn ログ化しラベル付与へ継続（呼び出し元を fail させない）（issue-watcher.sh:1063-1069）
- 4.3 — found 時 epoch を stdout に出力し return 0（issue-watcher.sh:849-851, 865-867）/ smoke #2,#12
- 4.4 — 双方不在で stdout 空 + return 1（issue-watcher.sh:869）/ smoke #9
- 4.5 — 破損ファイル（`jq -e` 非0）・非数値値は `^[0-9]+$` ガードで弾き return 1。stdout に数値以外を返さない（issue-watcher.sh:846-849）/ smoke #8,#11
- 4.6 — `process_quota_resume` は `qa_load_reset_time` が return 1 のとき `continue`（`needs-quota-wait` を除去しない）（issue-watcher.sh:1126-1129）
- 5.1 / 5.2 — escalation コメントから body marker 削除手順を除去し、`needs-quota-wait` → `claude-failed` 付け替えのみ案内（issue-watcher.sh:900-902）
- 5.3 — escalation コメントの Stage / reset epoch / ISO 8601 / grace 明記は従来どおり維持（issue-watcher.sh:884-889、未変更）
- 6.1 — README「reset 時刻の永続化方式」節をローカルファイル方式へ更新（README.md:2573-2602）
- 6.2 — README の escalation コメント例から body marker 削除手順を除去（README.md:2644-2645）
- 6.3 — README に移行期の本文 marker フォールバック読取の記述を追加（README.md:2588-2602）
- NFR 1.1 — `QUOTA_AWARE_ENABLED` / `QUOTA_RESUME_GRACE_SEC` の名前・受理形式・既定値（`true` / `60`）不変（issue-watcher.sh:376,379、未変更）
- NFR 1.2 — `QUOTA_AWARE_ENABLED != "true"` の早期 return gate 経路は未変更（issue-watcher.sh:715, 1100）
- NFR 1.3 — ラベル付与/除去タイミング・`claude-failed` 非同時付与の契約は未変更（diff は persist/load/escalation/log のみ）
- NFR 1.4 — 読取（0=found / 1=absent or malformed）・書込（0=persisted / 1=failure, warn only）の return 契約維持
- NFR 2.1 / 2.2 — persist 成功/失敗ログに `issue=#N` と `reset_epoch=` を含め grep 可能（issue-watcher.sh:1065,1068）
- NFR 3.1 — shellcheck 警告 29 件（main と同数。本変更による新規警告 0 件、再実行で確認）
- NFR 4.1 — 同一 Issue・同一 epoch の複数回 persist が upsert で 1 件に収束（issue-watcher.sh:818-821）/ smoke #5

## Boundary 確認

- 変更ファイルは `local-watcher/bin/issue-watcher.sh` / `README.md` / spec 配下のみ。Out of Scope（GitHub Actions 版 / クロスマシン共有 / 旧 marker 一括削除 / quota 検知ロジック / grace 算出）への変更混入なし
- 新規 env `QUOTA_RESET_STATE_FILE` は既定値ありで未設定環境は従来パス（`$LOG_DIR` 配下）に帰着し後方互換を壊さない

## Findings

なし

## Summary

requirements.md の全 numeric AC（Req 1〜6 / NFR 1〜4）に対応する実装・スモーク検証・README 更新を確認。
body read-modify-write の廃止・ローカルファイル優先＋marker フォールバック・return 契約維持・後方互換（env / ラベル / exit code）いずれも充足。boundary 逸脱・missing test・AC 未カバーなし。

RESULT: approve
