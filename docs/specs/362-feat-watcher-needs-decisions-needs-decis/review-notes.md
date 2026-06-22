# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-362-impl-feat-watcher-needs-decisions-needs-decis
- HEAD commit: c5b0c2aad34eedad527c137c7caf102bba514c5c
- Compared to: main..HEAD
- 主要変更ファイル: `local-watcher/bin/issue-watcher.sh` (+29 / Config block 追加 + cycle startup ログ拡張 + Triage handler 配線), `local-watcher/bin/modules/needs-decisions-auto.sh` (+312 新規 module / 全 8 関数), `local-watcher/bin/triage-prompt.tmpl` (+32 / classification 判定基準節 + JSON schema field), `.claude/agents/product-manager.md` (+8 / classification 出力責務), `local-watcher/test/needs_decisions_auto_test.sh` (+619 / 72 PASS), `README.md` (+181 / opt-in 表 + kill switch 行更新 + 詳細節), `repo-template/.claude/agents/product-manager.md` (+8 / 同期)

## Verified Requirements

- 1.1 — `NEEDS_DECISIONS_MODE` 既定値 `all-human`（`issue-watcher.sh:139` の `${NEEDS_DECISIONS_MODE:-all-human}`）
- 1.2 — `=all-human` 厳密一致（`issue-watcher.sh:140-142` case 文 / test Section 2 `assert_config_normalize "all-human" → all-human"`）
- 1.3 — `=classified` 厳密一致（同上 / test Section 2 で確認）
- 1.4 — `=all-auto` 厳密一致（同上 / test Section 2 で確認）
- 1.5 — 未設定 / 空 / 不正値は `all-human` 正規化（`*) NEEDS_DECISIONS_MODE="all-human"` / test Section 1 で 7 パターン、Section 2 で `auto` / `Classified` / `ALL-AUTO` / 空 / unset の 8 パターン）
- 1.6 — needs-decisions 判定より前に正規化完了（Config block は `issue-watcher.sh:139-143`、Triage handler は `:10528` 配置）
- 2.1 — `decisions[].classification` の必須出力（`triage-prompt.tmpl:121` JSON schema + `:133` 補足箇条書き）
- 2.2 — `human-only` 定義（機密 / コンプラ / 不可逆 / 外部影響）が `triage-prompt.tmpl:43-50` で 4 カテゴリ列挙
- 2.3 — `safe` の条件（推奨あり + 2.2 不該当）が `triage-prompt.tmpl:54-57` で明示
- 2.4 — fail-safe の文書化（`triage-prompt.tmpl:59-63` 「確信が持てない場合は必ず human-only」）+ 実装（`nda_extract_classification` の `else "human-only"` 分岐 / test Section 3 「classification 不明値 → human-only」）
- 2.5 — 機械可読格納（`decisions[].classification` field を jq で抽出 / `nda_extract_classification` 実装 + test Section 3 で 13 ケース）
- 3.1 — `classified` + `safe` 自動続行（`nda_evaluate_auto_continue` 判定順序 5 段目 / test Section 7 「classified + safe + rec → rc=0」）
- 3.2 — `all-auto` + `safe` 自動続行（同上 / test Section 7 「all-auto + safe + rec → rc=0」）
- 3.3 — 自動続行時 `needs-decisions` ラベル除去（`nda_auto_continue` は LABEL_NEEDS_DECISIONS を **付与しない**設計で「除去」を不要化 + `claude-claimed` のみ除去 / test Section 5 / 7 で `gh issue edit --remove-label` 観測）
- 3.4 — 採用 recommendation の Issue 記録（`nda_auto_continue` heredoc で本文構成 + `gh issue comment` 投稿 / test Section 5 / 7 でコメント投稿 1 回観測）
- 4.1 — `human-only` モードによらず停止（`nda_evaluate_auto_continue` 3 段目分岐 / test Section 8 で classified + human-only / all-auto + human-only 双方 halt 確認）
- 4.2 — `classified` + `human-only` 停止（test Section 8 で gh ゼロ呼び出し + `cause=classification-human-only` ログ）
- 4.3 — `all-auto` + `human-only` 停止（test Section 8 「all-auto + human-only → rc=1 (hard boundary halt)」）
- 4.4 — 分類欠落 / 不明は `human-only` 扱い（`nda_extract_classification` の null / 欠落 / 空配列 / decisions key 不在 / decisions null / 不明値 / 不正 JSON / file 不在を test Section 3 で 13 ケース確認）
- 4.5 — `safe` + `human-only` 混在は `human-only`（`nda_extract_classification` の `any(.=="human-only")` 優先評価 / test Section 3 で順序順 / 逆順 2 ケース + Section 8 で評価エントリ経由でも halt）
- 5.1 — `all-human` 既定で導入前と等価（`nda_evaluate_auto_continue` 2 段目で mode=all-human halt + gh API ゼロ呼び出し / test Section 6）
- 5.2 — `FULL_AUTO_ENABLED=false` で自動続行しない（`nda_evaluate_auto_continue` 1 段目で kill switch halt / test Section 6 「kill OFF → rc=1 + gh ゼロ + suppression ログ」）
- 5.3 — kill ON + mode=all-human で自動続行しない（test Section 6 「kill ON + mode=all-human → rc=1 + gh ゼロ + cause=mode-all-human ログ」）
- 5.4 — AND 二重 opt-in（kill ON AND mode != all-human）（test Section 7 で kill ON + classified / all-auto の双方で auto-continue 観測）
- 5.5 — 既存 non-full-auto 機能は本 mode に依存しない（`NEEDS_DECISIONS_MODE` の参照は `nda_*` 関数群と本体 Config / Triage handler / startup ログ行のみで完結。`grep NEEDS_DECISIONS_MODE issue-watcher.sh` で配線箇所が限定的）
- 6.1 — mode + classification + action のログ（`nda_log "issue=#... mode=... classification=... action=..."` 形式 / test Section 5 / 7 で action=auto-continue ログ観測）
- 6.2 — kill switch OFF 起因の suppression ログ（`cause=suppressed-by-FULL_AUTO_ENABLED` / test Section 6 で確認）
- 6.3 — `human-only` 起因の suppression ログ（`cause=classification-human-only` / test Section 8 で確認）
- 6.4 — cycle startup に mode 値を出力（`issue-watcher.sh:981` の echo 行に `needs-decisions-mode=${NEEDS_DECISIONS_MODE}` を追記）
- NFR 1.1 — 既定 mode で byte-equivalent（`nda_evaluate_auto_continue` 1〜2 段目で早期 return + gh API ゼロ呼び出し / test Section 6 で kill OFF / kill ON + all-human 双方で `count_calls "^gh "` = 0 確認）
- NFR 1.2 — 既存 env / label / exit code 不変（新 env `NEEDS_DECISIONS_MODE` のみ追加 / 既存 `LABEL_NEEDS_DECISIONS` / `LABEL_CLAIMED` 再利用 / 新ラベル新設なし）
- NFR 1.3 — 既存 needs-decisions 付与経路の挙動不変（本機能は Triage handler の冒頭で nda 経由 rc=0 時のみ既存処理を skip。rc=1 時は既存処理に流れ byte-equivalent）
- NFR 2.1 — README opt-in 表 + 詳細節（`README.md:1360` 表追加 + `:3587` 詳細節新設）
- NFR 2.2 — root ↔ repo-template byte 一致（`diff -r .claude/agents repo-template/.claude/agents` exit 0 確認。`repo-template/local-watcher/` は本 repo の配布形態上不在＝対象外、impl-notes task 8 で確認済）
- NFR 2.3 — Triage / PM agent 定義に分類タグ意味記載（`triage-prompt.tmpl` + `product-manager.md` 双方に classification 出力責務記述）
- NFR 3.1 — `shellcheck` / `bash -n` pass（reviewer 側で `shellcheck local-watcher/bin/modules/needs-decisions-auto.sh local-watcher/bin/issue-watcher.sh` 警告ゼロ + `bash -n` 双方 pass を再確認）
- NFR 3.2 — 近接 test の AC カバレッジ（5 ケース要求 / `needs_decisions_auto_test.sh` で 72 PASS / Section 6 で human-only halts under classified, Section 8 で human-only halts under all-auto, Section 7 で safe auto-continues under classified, Section 6 で unset mode → all-human 等価, Section 6 で FULL_AUTO_ENABLED=false suppression すべて確認）
- NFR 3.3 — env 不正値 → all-human の test（Section 1 で `Classified` / `auto` / 空文字 / unset、Section 2 で `auto` / `Classified` / `ALL-AUTO` / 空 / unset を確認）
- NFR 4.1 — 機密 / API key / 個人情報 / コンプラ / 契約 / 不可逆は human-only（`triage-prompt.tmpl:43-50` の 4 カテゴリ列挙が CLAUDE.md「機密情報の扱い」と整合）
- NFR 4.2 — `all-auto` でも human-only halt は hard boundary（`nda_evaluate_auto_continue` 判定順序の 3 段目（classification）が 2 段目（mode）より下流かつ classification=human-only は無条件 halt / test Section 8 「all-auto + human-only → rc=1 + gh ゼロ + cause=classification-human-only ログ」で確認）

## Findings

なし

## Summary

全 6 Requirements (1〜6) + NFR 1〜4 の AC を `requirements.md` の numeric ID 単位でチェックした結果、すべての AC が実装または該当テストでカバーされていた（needs_decisions_auto_test.sh は 72 PASS / 0 FAIL、shellcheck / bash -n も pass、root ↔ repo-template の `.claude/agents` 差分ゼロ）。tasks.md の `_Boundary:_` 列挙範囲（`issue-watcher.sh Config block / Triage handler` / `needs-decisions-auto.sh` / `triage-prompt.tmpl` / `.claude/agents/product-manager.md` / `README.md` / `repo-template/`）外への変更も検出されず、3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）いずれにも該当しない。CLAUDE.md の Feature Flag Protocol セクションは root 側に未宣言で opt-out 扱いのため、flag 観点の追加判定は適用しない。

RESULT: approve
