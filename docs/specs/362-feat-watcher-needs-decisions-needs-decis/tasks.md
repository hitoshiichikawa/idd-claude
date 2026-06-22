# Implementation Plan

> 設計成果物: `docs/specs/362-feat-watcher-needs-decisions-needs-decis/design.md`
> 関連: Issue #362 / Depends on: #348（FULL_AUTO_ENABLED kill switch、merge 済み）
>
> **per-task Reviewer 運用時の境界注記**: `PER_TASK_LOOP_ENABLED=true` の運用下では、各
> behavior-changing task の対応 unit test が **task 6 (`needs_decisions_auto_test.sh`)** に集約されて
> いる。task 1〜5 の `_Requirements:_` のうち、対応 unit test が task 6 に deferred されている AC は
> `_Requirements_partial:_` で明示している（Reviewer は当該 AC を `missing test` reject 対象から除外し、
> task 6 で partial 解消を確認する）。

- [x] 1. env 正規化と cycle startup ログ拡張
  - `local-watcher/bin/issue-watcher.sh` の Config block（`FULL_AUTO_ENABLED` 正規化直後、行 ~133 近辺）
    に `NEEDS_DECISIONS_MODE` を追加。既定 `all-human`、`case ... esac` で 3 値（`all-human` /
    `classified` / `all-auto`）以外は `all-human` に正規化（既存 `AUTO_REBASE_MODE` パターン踏襲）
  - cycle startup ログ行（`local-watcher/bin/issue-watcher.sh:968`）の末尾に
    ` needs-decisions-mode=${NEEDS_DECISIONS_MODE}` を追記
  - 最小スモーク（本 task 内）: `bash -n local-watcher/bin/issue-watcher.sh` と
    `shellcheck local-watcher/bin/issue-watcher.sh` が pass、`NEEDS_DECISIONS_MODE=auto $HOME/bin/issue-watcher.sh`
    を対象なし状態で流し、cycle startup ログに `needs-decisions-mode=all-human` が出力されることを目視確認
    （regression coverage の本格 unit test は task 6 に deferred）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 6.4_
  - _Requirements_partial: 1.5_
  - _Boundary: issue-watcher.sh Config block_

- [x] 2. needs-decisions-auto.sh module の新規追加（関数定義のみ）
- [x] 2.1 module ファイル雛形 + ロガー（nda_log / nda_warn / nda_error）
  - `local-watcher/bin/modules/needs-decisions-auto.sh` を新規作成。冒頭コメントで「用途 / 配置先 /
    依存 / セットアップ参照先」を明記（既存 `auto-merge.sh` `failed-recovery.sh` 形式に揃える）
  - 関数 prefix `nda_` を明示。`[YYYY-MM-DD HH:MM:SS] [$REPO] needs-decisions-auto:` 3 段 prefix ロガー
    を実装（stdout 用 `nda_log`、stderr 用 `nda_warn` / `nda_error`）
  - トップレベル副作用を持たせない（関数定義のみ。`extract_function` テストイディオムの前提）
  - 最小スモーク: `bash -n local-watcher/bin/modules/needs-decisions-auto.sh` と
    `shellcheck local-watcher/bin/modules/needs-decisions-auto.sh` が pass
  - _Requirements: 6.1, 6.2, 6.3_
  - _Boundary: needs-decisions-auto.sh_

- [x] 2.2 mode 解決 + classification 抽出 + recommendation 抽出の純関数
  - `nda_resolve_mode_enabled()` を実装: `NEEDS_DECISIONS_MODE` が `classified` / `all-auto` の場合
    rc=0、`all-human` の場合 rc=1（本体 Config で正規化済前提）
  - `nda_extract_classification(triage_json_path)` を実装: jq で `decisions[].classification` を抽出し、
    `human-only` 単独 / 混在 / 欠落 / null / 空 / 空 decisions[] / jq 失敗 / file 不在のすべてで
    `"human-only"` を返す fail-safe。`safe` のみ全件揃った場合のみ `"safe"` を返す
  - `nda_extract_first_recommendation(triage_json_path)` を実装: `decisions[0].recommendation` を抽出し、
    空文字 / null / 抽出失敗時 rc=1
  - jq に値を渡す際は `--arg` を使い、`--` で grep / git / gh のオプション解釈を打ち切る（CLAUDE.md
    「機能追加ガイドライン § 5 未信頼入力」準拠）
  - 純関数のため副作用なし。fail-safe / 異常系の unit test は task 6 で集約（safety-side fallback の
    AC カテゴリに該当するため、partial 明示）
  - _Requirements: 2.4, 2.5, 4.4, 4.5, NFR 4.2_
  - _Requirements_partial: 2.4, 2.5, 4.4, 4.5, NFR 4.2_
  - _Boundary: needs-decisions-auto.sh_
  - _Depends: 2.1_

- [x] 2.3 auto-continue 実行関数 nda_auto_continue
  - `nda_auto_continue(triage_json_path, first_recommendation_body)` を実装:
    1. `gh issue comment "$NUMBER" --repo "$REPO" --body "$body"` で採用 recommendation +
       mode + classification + 監査用 fingerprint を投稿（best-effort、失敗時は WARN + return 1）
    2. **コメント投稿成功時のみ** `gh issue edit "$NUMBER" --repo "$REPO" --remove-label
       "$LABEL_CLAIMED"` を実行（`LABEL_NEEDS_DECISIONS` は **付与しない**ことで「除去」を不要化 /
       Req 3.3）
    3. `nda_log` 1 行で action=auto-continue / mode / classification / recommendation 先頭を記録
  - 既存 `mark_issue_needs_decisions` の best-effort 方針に整合
  - 副作用を持つため失敗 path の unit test は task 6 で集約（partial 明示）
  - _Requirements: 3.3, 3.4, 6.1_
  - _Requirements_partial: 3.3, 3.4_
  - _Boundary: needs-decisions-auto.sh_
  - _Depends: 2.1, 2.2_

- [x] 2.4 判定エントリ nda_evaluate_auto_continue（AND 二重 opt-in / 判定順序）
  - `nda_evaluate_auto_continue(triage_json_path)` を実装。判定順序（design.md「Service Interface」節）:
    1. `full_auto_enabled` が rc=1 → halt（log: `suppressed by FULL_AUTO_ENABLED`、Req 5.2 / 6.2）
    2. `nda_resolve_mode_enabled` が rc=1 → halt（log: `mode=all-human action=halt`、Req 5.3 / 6.1）
    3. `nda_extract_classification` が `human-only` → halt（log: `classification=human-only action=halt
       cause=classification-human-only`、Req 4.1〜4.5 / 6.3）
    4. `nda_extract_first_recommendation` が rc=1 → halt（log: `recommendation=missing action=halt`）
    5. 全 pass → `nda_auto_continue` を call し、成功時 rc=0 を返す（log: `mode=<mode>
       classification=safe action=auto-continue`、Req 3.1 / 3.2 / 6.1）
  - kill switch OFF 起因は既存 #348 ログに委ねつつ nda 側でも 1 行記録（Req 6.2）
  - 判定順序の AND 二重 opt-in / human-only halt / fail-safe の unit test は task 6 で集約
    （regression coverage / safety-side fallback の AC カテゴリのため partial 明示）
  - _Requirements: 3.1, 3.2, 4.1, 4.2, 4.3, 5.2, 5.3, 5.4, 6.1, 6.2, 6.3_
  - _Requirements_partial: 3.1, 3.2, 4.1, 4.2, 4.3, 5.2, 5.3, 5.4_
  - _Boundary: needs-decisions-auto.sh_
  - _Depends: 2.1, 2.2, 2.3_

- [x] 3. 本体への配線（REQUIRED_MODULES 登録 + Triage 結果ハンドラ分岐）
  - `local-watcher/bin/issue-watcher.sh:889` の `REQUIRED_MODULES` 配列に `needs-decisions-auto.sh` を
    追加（順序は機能的に任意、可読性のため末尾近辺）
  - Triage 結果ハンドラ（`local-watcher/bin/issue-watcher.sh:10506-10542`）の `if [ "$STATUS" =
    "needs-decisions" ] && [ "$DECISION_COUNT" -gt 0 ]; then` ブロック **冒頭**で
    `if nda_evaluate_auto_continue "$TRIAGE_FILE"; then return 0; fi` を呼ぶ
  - nda_evaluate_auto_continue が rc=0（auto-continue 成功）の場合は既存の COMMENT 組み立て + gh issue
    comment + ラベル付け替え + return 0 を **すべて skip** して即 return 0（Issue は
    `needs-decisions` ラベル不付与 + `claude-claimed` 除去済の状態 → 次サイクルで dispatcher 再 pickup）
  - rc=1（halt）の場合は既存処理に流す（本機能導入前と完全等価 / NFR 1.1, 1.3）
  - 最小スモーク: `bash -n` + `shellcheck` 通過、`module_loader_missing_test.sh` パターンで配線が
    壊れていないことを既存テスト群でも確認
  - 配線の E2E regression（既存付与経路を壊さない / dispatcher 再 pickup が走る）は手動スモークで
    task 7 / 8 完了後に確認（API・parse failure handling は task 6 unit test 側でカバー）
  - _Requirements: 3.1, 3.2, 3.3, 4.1, 4.2, 4.3, 5.1, 5.4, NFR 1.1, NFR 1.3_
  - _Requirements_partial: 3.1, 3.2, 3.3, 4.1, 4.2, 4.3_
  - _Boundary: issue-watcher.sh Triage handler, needs-decisions-auto.sh_
  - _Depends: 1, 2.4_

- [x] 4. Triage prompt 拡張（classification field と判定基準の追加）
  - `local-watcher/bin/triage-prompt.tmpl` の「## 「致命的に人間の判断が必要」と判定する基準」節
    （行 23-36）と並列に「## 分類タグ（classification）の判定基準」節を新規追加
    - `human-only` 定義: 機密情報 / API key / OAuth token / 個人情報 / 認証情報 / コンプライアンス /
      法務 / 契約 / ライセンス / 不可逆な変更（schema migration / data delete / branch protection 緩和 /
      公開済み API 互換性破壊）/ 外部影響（本番環境 / 課金 / 外部サービス新規依存）のいずれか
    - `safe` 条件: 上記すべてに該当せず、かつ PM が `recommendation` で明確な第一推奨を提示できる
    - fail-safe: 判定に確信が持てなければ **必ず** `human-only`
  - 「## 出力形式」節（行 74-101）の JSON スキーマ `decisions[]` 要素に `"classification": "safe" |
    "human-only"` フィールドを追加（既存 5 fields の位置・型・意味は不変 / NFR 1.2）
  - `status = "needs-decisions"` 時は **必須**、`status = "ready"` 時は decisions 空配列なので出現
    余地なし
  - prompt template の挙動検証は LLM 側の応答品質に依存するため近接 unit test では検証しない
    （E2E スモークは task 7 / 8 完了後に手動で実施）
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, NFR 2.3, NFR 4.1_
  - _Boundary: triage-prompt.tmpl_

- [x] 5. PM agent 定義に classification 出力責務を追記
  - `.claude/agents/product-manager.md` の「# Triage モードで呼ばれた場合」節（行 120-124）末尾に
    5-8 行で classification 出力責務を追記:
    - `status = "needs-decisions"` の各 decisions について `classification: "safe" | "human-only"` を
      必須出力
    - `human-only` 定義（機密 / コンプラ / 不可逆 / 外部影響）と詳細基準は `triage-prompt.tmpl` 側参照
    - 確信が持てない場合は必ず `human-only`（fail-safe）
  - 詳細判定基準は重複記載しない（`triage-prompt.tmpl` が canonical）
  - _Requirements: NFR 2.3_
  - _Boundary: .claude/agents/product-manager.md_

- [x] 6. 近接テスト追加（needs_decisions_auto_test.sh）— deferred test の partial 解消
  - `local-watcher/test/needs_decisions_auto_test.sh` を新規作成。既存 `full_auto_enabled_test.sh` の
    `extract_function` イディオムを踏襲（awk による単一関数切り出し + eval + stub）
  - 検証ケース（task 1〜2.4 / 3 で deferred した AC のテスト追加を **本 task で集約解消**）:
    1. `nda_resolve_mode_enabled` 正規化（NFR 3.3、task 1 partial 解消の 1.5 一部）: `all-human` → rc=1
       / `classified` → rc=0 / `all-auto` → rc=0 / 未設定 → rc=1 / 空文字 → rc=1 / `Classified` → rc=1
       / `auto` → rc=1
    2. 本体 Config block の正規化スモーク（task 1 partial 解消の 1.5）: `NEEDS_DECISIONS_MODE=auto`
       で本体 Config 行を awk で抽出 evaluate し、正規化結果が `all-human` になることを確認
    3. `nda_extract_classification` fail-safe（task 2.2 partial 解消の 2.4, 2.5, 4.4, 4.5, NFR 4.2）:
       `safe` 単独 → "safe" / `human-only` 単独 → "human-only" / safe+human-only 混在 → "human-only"
       / classification 欠落 → "human-only" / null → "human-only" / decisions[] 空 → "human-only" /
       jq 失敗 (不正 JSON) → "human-only"
    4. `nda_extract_first_recommendation`: 正常抽出 → rc=0 + 本文 / 空文字 → rc=1 / null → rc=1 /
       decisions[] 空 → rc=1
    5. `nda_auto_continue` のエラーパス（task 2.3 partial 解消の 3.3, 3.4）: gh issue comment 失敗 →
       rc=1 + ラベル除去 skip / gh issue edit 失敗 → rc=1 + WARN ログ
    6. `nda_evaluate_auto_continue` 判定順序 NFR 1.1（task 2.4 partial 解消の 5.2, 5.3, 5.4）: kill OFF
       + mode=classified + safe → halt（gh stub 呼び出し件数ゼロ + suppression ログ）
    7. `nda_evaluate_auto_continue` AND 二重 opt-in（task 2.4 partial 解消の 3.1, 3.2, 5.4 + task 3
       partial 解消の 3.1, 3.2, 3.3）: kill ON + mode=classified + safe + valid recommendation →
       auto-continue（gh issue comment + gh issue edit が呼ばれる、stub で観測）
    8. `nda_evaluate_auto_continue` human-only halt（task 2.4 partial 解消の 4.1, 4.2, 4.3 + task 3
       partial 解消の 4.1, 4.2, 4.3、NFR 4.2 hard boundary）: kill ON + mode=all-auto + human-only →
       halt（gh ゼロ呼び出し + suppression ログ）
  - stub: `gh` / `full_auto_enabled` を関数で override し、呼び出しトレースを一時ファイルに記録
  - `bash local-watcher/test/needs_decisions_auto_test.sh` で全 PASS することを確認
  - _Requirements: 1.5, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 4.4, 4.5, 5.2, 5.3, 5.4, NFR 3.2, NFR 3.3, NFR 4.2_
  - _Boundary: needs_decisions_auto_test.sh, needs-decisions-auto.sh_
  - _Depends: 1, 2.4, 3_

- [x] 7. README 更新（オプション機能表 + 詳細節 + kill switch 配線対象更新）
  - `README.md` の「### opt-in（既定 OFF、明示的に有効化が必要）」表（行 1349 近辺）に
    `NEEDS_DECISIONS_MODE` を 1 行追加:
    - 機能名 / 制御変数 / 既定 (`all-human`) / 正規化規則（3 値以外は `all-human` 安全側） /
      必須前提（`FULL_AUTO_ENABLED=true` AND 評価）/ 詳細リンク / 関連 (`#362, #348`)
  - 「Full-Auto Kill Switch」表行（行 1367 近辺）の説明文「本 Issue 時点の配線対象は Dependency
    Auto-Unblock Sweep のみ」を「Dependency Auto-Unblock Sweep + needs-decisions auto」に更新
    （**ただし auto-merge / failed-recovery / pr-reviewer-status は既に独自に AND 配線**されている
    既存記述があれば矛盾しないよう調整、整合確認後に修正）
  - 詳細節を新設（`Auto-Merge Processor (#352)` などと同じ階層の独立節として追記）:
    - 3 値モードの意味と挙動
    - AND 二重 opt-in（`FULL_AUTO_ENABLED` AND `NEEDS_DECISIONS_MODE != all-human`）
    - 既定 `all-human` での pre-introduction 等価保証（NFR 1.1）
    - `human-only` 絶対停止 + fail-safe to human-only（NFR 4.x）
    - 観測ログ grep 例（`grep needs-decisions-auto:` / `grep needs-decisions-mode=`）
    - cron 設定例（`FULL_AUTO_ENABLED=true NEEDS_DECISIONS_MODE=classified` 最小例）
    - pilot 運用先 = altpocket-server / Out of Scope（rollout 判断は別 Issue）
  - _Requirements: NFR 2.1_
  - _Boundary: README.md_
  - _Depends: 1, 2, 3, 4_

- [x] 8. root ↔ repo-template 二重管理同期（byte 一致確認）
  - `repo-template/local-watcher/bin/issue-watcher.sh` ← `local-watcher/bin/issue-watcher.sh` を同期
  - `repo-template/local-watcher/bin/triage-prompt.tmpl` ← `local-watcher/bin/triage-prompt.tmpl` を同期
  - `repo-template/local-watcher/bin/modules/needs-decisions-auto.sh` を新規配置
  - `repo-template/local-watcher/test/needs_decisions_auto_test.sh` を新規配置（既存 test と同様、
    repo-template 配下にも配置する慣習に従う場合のみ。既存 test の repo-template 配下配布状況を
    `diff -r local-watcher/test repo-template/local-watcher/test` で先に確認し、配布対象なら追加 /
    非対象なら本項 skip）
  - `repo-template/.claude/agents/product-manager.md` ← `.claude/agents/product-manager.md` を同期
  - 検証:
    - `diff -r .claude/agents repo-template/.claude/agents` が空
    - `diff -r .claude/rules repo-template/.claude/rules` が空（本機能では rules 更新なしのため
      既存も空のはず）
    - `diff -r local-watcher/bin repo-template/local-watcher/bin` が空
  - CLAUDE.md「機能追加ガイドライン § 4 二重管理・同期の鉄則」を順守
  - _Requirements: NFR 2.2_
  - _Boundary: repo-template/_
  - _Depends: 1, 2, 3, 4, 5_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを
構造化ブロックで宣言する。`needs_decisions_auto_test.sh` 近接テスト + 既存 module の
shellcheck baseline 維持 + 本体 syntax check + root↔repo-template ドリフトゼロ確認の
4 点を pass させる。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/needs-decisions-auto.sh local-watcher/bin/issue-watcher.sh && bash -n local-watcher/bin/modules/needs-decisions-auto.sh && bash -n local-watcher/bin/issue-watcher.sh && bash local-watcher/test/needs_decisions_auto_test.sh && diff -r .claude/agents repo-template/.claude/agents && diff -r local-watcher/bin repo-template/local-watcher/bin
```
