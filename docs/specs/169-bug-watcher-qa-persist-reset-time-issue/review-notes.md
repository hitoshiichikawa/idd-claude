# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T12:33:12Z -->

## Reviewed Scope

- Branch: claude/issue-169-impl-bug-watcher-qa-persist-reset-time-issue
- HEAD commit: 744e86b（実装本体: cac8aa0）
- Compared to: main..HEAD
- Feature Flag Protocol: 対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節が存在しない
  ため **opt-out 扱い**。flag 観点（boundary 逸脱の細目）は適用せず、通常の 3 カテゴリ判定のみ実施。
- 注: 本 spec には `design.md` / `tasks.md` が存在しない（`requirements.md` のみ確定。impl-notes.md
  でも明記）。したがって `_Boundary:_` アノテーションは無く、boundary 判定は requirements.md の
  Out of Scope と変更ファイルパスの突き合わせで実施した。

## Verified Requirements

- 1.1 — `qa_persist_reset_time` が `$QUOTA_RESET_STATE_FILE`（既定 `$LOG_DIR/quota-reset-times.json`）へ
  書込（issue-watcher.sh:789-826）。独立 smoke で readback 一致を確認（persist 100=1700000000 → load 一致）
- 1.2 / 1.3 — 書込関数 `qa_persist_reset_time`（789-826）から `gh issue view` / `gh issue edit --body`
  を完全除去。body の read-modify-write を廃止。range 内に残る `gh issue view` は読取側
  `qa_load_reset_time`（858）のフォールバック read のみで、書込経路に body 上書きなし
- 1.4 — `LOG_DIR`（`$HOME/.issue-watcher/logs/<repo_slug>`、repo slug 分離済み）配下に配置。
  他 repo の値は同一ファイルに混在しない（issue-watcher.sh:776）
- 2.1 / 2.2 — Issue 番号を文字列キーとする JSON `{ "<num>": <epoch> }`。読取は `.[$num]` で当該
  Issue のみ取得（issue-watcher.sh:847-849）。独立 smoke で issue100/issue200 が別個に取得できることを確認
- 2.3 — `jq '. + {($num): $epoch}'` の upsert で 1 Issue 最新値 1 件に収束（issue-watcher.sh:818-821）。
  独立 smoke で upsert 後に最新値のみ・key 1 個を確認
- 3.1 / 3.3 — `qa_load_reset_time` がローカルファイルを先に参照し、有効値があれば即 return（body
  marker より優先）（issue-watcher.sh:843-853）。独立 smoke で local-priority（999 をローカルに書くと
  marker でなくローカル値を返す）を確認
- 3.2 / 3.4 — ローカルに有効値が無い場合のみ body の `<!-- idd-claude:quota-reset:<epoch>:v1 -->`
  をフォールバック読取（issue-watcher.sh:855-868）。独立 smoke で fallback-marker（999）を確認
- 4.1 — 書込成功で return 0、不正 epoch / mkdir / mktemp / jq / mv 失敗で return 1
  （issue-watcher.sh:789-825）。独立 smoke で persist-ret0 / malformed-persist-ret1 を確認
- 4.2 — `qa_handle_quota_exceeded` は persist 失敗を warn ログ化しラベル付与へ継続（呼び出し元を
  fail させない）（issue-watcher.sh:1063-1069）
- 4.3 — found 時 epoch を stdout に出力し return 0（issue-watcher.sh:850-851, 866-867）。
  独立 smoke で readback / stringval-sibling 影響なしを確認
- 4.4 — 双方不在で stdout 空 + return 1（issue-watcher.sh:869）。独立 smoke で absent-ret1 を確認
- 4.5 — 破損ファイル（`jq -e` 非0）・非数値値は `^[0-9]+$` ガードで弾き return 1。stdout に数値以外を
  返さない（issue-watcher.sh:843-852, 865）。独立 smoke で corrupt-ret1 / corrupt-stdout-empty /
  stringval-ret1 を確認
- 4.6 — `process_quota_resume` は `qa_load_reset_time` が return 1 のとき `continue`
  （`needs-quota-wait` を除去せずラベル維持）（issue-watcher.sh:1126-1129）
- 5.1 / 5.2 — escalation コメントから body marker 削除手順を除去し、`needs-quota-wait` →
  `claude-failed` 付け替えのみ案内する文面に修正（issue-watcher.sh:900-902）
- 5.3 — escalation コメントの Stage / reset epoch / ISO 8601 / grace 明記は従来どおり維持
  （issue-watcher.sh:885-889、未変更）
- 6.1 — README「reset 時刻の永続化方式」節をローカルファイル方式へ更新（README.md diff 2573-2602）
- 6.2 — README の escalation コメント例から body marker 削除手順を除去（README.md diff 2644-2645）
- 6.3 — README に移行期の本文 marker フォールバック読取の記述を追加（README.md diff 2586-2602）
- NFR 1.1 — `QUOTA_AWARE_ENABLED` / `QUOTA_RESUME_GRACE_SEC` の名前・受理形式・既定値（`true` / `60`）
  不変（diff に env default 変更なし）
- NFR 1.2 — `QUOTA_AWARE_ENABLED != "true"` の早期 return gate 経路は未変更（issue-watcher.sh:1100）
- NFR 1.3 — ラベル付与/除去タイミング・`claude-failed` 非同時付与の契約は未変更（diff は persist /
  load / escalation 文面 / log 行のみ）
- NFR 1.4 — 読取（0=found / 1=absent or malformed）・書込（0=persisted / 1=failure, warn only）の
  return 契約維持（関数 docstring と実装で確認）
- NFR 2.1 / 2.2 — persist 成功/失敗ログに `issue=#N` と `reset_epoch=` を含め grep 可能
  （issue-watcher.sh:1065, 1068）
- NFR 3.1 — `shellcheck local-watcher/bin/issue-watcher.sh` を main と HEAD で再実行し、いずれも
  29 件（本変更による新規警告 0 件）
- NFR 4.1 — 同一 Issue・同一 epoch の複数回 persist が upsert で 1 件に収束（issue-watcher.sh:818-821）。
  独立 smoke の upsert / single-key で確認

## Boundary 確認

- 変更ファイルは `local-watcher/bin/issue-watcher.sh` / `README.md` / spec 配下（`docs/specs/169-.../`）
  のみ。Out of Scope（GitHub Actions 版ワークフロー / クロスマシン共有 / 旧 marker 一括削除 /
  quota 検知ロジック / grace 算出ロジック）への変更混入なし
- 新規 env `QUOTA_RESET_STATE_FILE` は既定値ありで未設定環境は従来パス（`$LOG_DIR` 配下）に帰着し、
  既存 env var 名・後方互換を壊さない（CLAUDE.md「禁止事項」に抵触しない）

## Findings

なし

## Summary

requirements.md の全 numeric AC（Req 1〜6 / NFR 1〜4）に対応する実装を確認し、独立 smoke 15 ケース
全 PASS・shellcheck 新規警告 0 件・README 更新を裏取りした。body read-modify-write の廃止 /
ローカルファイル優先＋marker フォールバック / return 契約維持 / 後方互換（env / ラベル / exit code）
いずれも充足。AC 未カバー・missing test・boundary 逸脱なし。

RESULT: approve
