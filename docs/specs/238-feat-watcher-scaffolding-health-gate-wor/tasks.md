# Implementation Plan

- [x] 1. scaffolding-health.sh モジュール骨格と logger / 検査純関数を作成
- [x] 1.1 新規モジュール `scaffolding-health.sh` を作成し logger と検査純関数を実装
  - `local-watcher/bin/modules/scaffolding-health.sh` を新規作成。ファイル冒頭コメントに
    「用途 / 配置先（`$HOME/bin/modules/scaffolding-health.sh`）/ 依存 / セットアップ参照先」を
    `stage-a-verify.sh` / `core_utils.sh` と同形式で明記する
  - `sh_log` / `sh_warn` / `sh_error` を `scaffolding-health:` 3 段 prefix
    （`[YYYY-MM-DD HH:MM:SS] [$REPO] scaffolding-health:`）で実装（`sav_*` と同形式）
  - `sh_inspect_scaffolding`（純関数・read-only）を実装。$1=worktree 絶対パス、配下の
    `.claude/agents` / `.claude/rules` に非空通常ファイルが各 1 つ以上あるかを `find -type f -size +0c`
    相当で判定。戻り値 0=full / 1=missing（stdout に `agents=<ok|missing> rules=<ok|missing>`）/
    2=indeterminate（真の I/O 異常のみ）。副作用なし・同一状態で同一結果
  - `set -euo pipefail` は宣言しない（本体側で宣言済み・関数定義のみ）
  - _Requirements: 1.1, 1.5, 3.1, 5.1, 5.3, NFR 1.1, NFR 5.1_

- [ ] 2. preflight gate と可視シグナルを実装し本体 call site / Config / module source を結線
- [x] 2.1 可視シグナル `_sh_emit_visibility_signal` と gate `sh_preflight_gate` を実装
  - `_sh_emit_visibility_signal`（$1=欠落サマリ）: `gh issue comment "$NUMBER" --repo "$REPO"` で
    投稿。本文に機械可読マーカー `<!-- scaffolding-health:missing -->` を埋め、投稿前に
    `gh issue view --json comments` で同マーカー既存を確認し重複投稿を抑止（冪等）。投稿失敗・
    確認失敗は `|| sh_warn` で吸収（fail-open）。常に 0 を返す
  - `sh_preflight_gate`（$1=worktree）: `sh_inspect_scaffolding` を呼び、full→`outcome=pass` を
    1 行ログして 0、missing→loud `sh_warn`（欠落内容含む）＋`_sh_emit_visibility_signal`、
    indeterminate→`sh_warn` ＋継続（戻り値 0）。1 回の呼び出しで必ず 1 行以上ログ
  - missing 時の `SCAFFOLDING_HEALTH_HALT` 値正規化: `on` 厳密一致のみ HALT（戻り値 1）、それ以外
    （`off`/未設定/空/`true`/`On`/typo）は `outcome=continue` で戻り値 0。indeterminate は HALT 設定
    でも停止に倒さず継続（Req 3.3）
  - _Requirements: 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 3.1, 3.2, 3.3, NFR 2.1_
  - _Boundary: scaffolding-health.sh_
- [ ] 2.2 本体へ env 定義・module source・preflight gate call site を結線
  - `issue-watcher.sh` Config ブロック（`STAGE_A_VERIFY_*` 近傍）に `SCAFFOLDING_HEALTH_HALT="${SCAFFOLDING_HEALTH_HALT:-off}"`
    を追加し、既定挙動（可視化のみ）を変えないコメントを付す
  - `REQUIRED_MODULES` 配列末尾に `"scaffolding-health.sh"` を 1 要素追加
  - `_slot_run_issue` 内 `_worktree_inject_claude "$SRC_REPO_DIR" "$WT"`（L6820）直後・`_hook_invoke`
    （L6823）直前に `if ! sh_preflight_gate "$WT"; then ...; return 0; fi` を挿入。HALT 分岐では
    `claude-claimed` / `claude-picked-up` を除去（`claude-failed` は付けない）し `slot_log` で
    人間判断待ちを記録して `return 0`
  - 既存 env 名 / ラベル契約 / exit code 意味 / ログ書式を変更しないことを確認
  - _Requirements: 1.1, 2.2, 5.2_
  - _Boundary: issue-watcher.sh, scaffolding-health.sh_
  - _Depends: 2.1_

- [ ] 3. doctor 点検項目群と統合ランナー sh_doctor_run を実装
- [ ] 3.1 doctor 点検項目 `sh_doctor_check_*` を実装（全 read-only）
  - `sh_doctor_check_scaffolding`: REPO_DIR の `.claude/agents,rules` 非空到達性（`sh_inspect_scaffolding`
    流用、$1=REPO_DIR）（Req 4.2）
  - `sh_doctor_check_clis`: `command -v gh jq flock git claude` の存否（Req 4.3）
  - `sh_doctor_check_labels`: `gh label list --json name`（read-only）で必須ラベル集合の存否。
    必須ラベル集合を doctor 側に明示列挙し `idd-claude-labels.sh` との乖離注意コメントを残す（Req 4.4）
  - `sh_doctor_check_base_branch`: `git -C "$REPO_DIR" rev-parse --verify "origin/$BASE_BRANCH"`
    （read-only）で解決可否を判定（Req 4.5）
  - 各点検は stdout に `  <項目名>: <ok|degraded|unknown> (<詳細>)`、戻り値 0=ok/1=degraded。
    git 作業ツリー・index・refs を変更せず Issue/PR/ラベルへ書き込まない
  - _Requirements: 4.2, 4.3, 4.4, 4.5, 4.7, NFR 4.1_
  - _Boundary: scaffolding-health.sh_
- [ ] 3.2 統合ランナー `sh_doctor_run` とトップレベル `--doctor` ディスパッチを実装
  - `sh_doctor_run`: env REPO/REPO_DIR/BASE_BRANCH で全 `sh_doctor_check_*` を集約し、ヘッダ＋各項目＋
    `RESULT: <full|degraded>` 一覧をレポート。1 項目でも degraded なら repo 全体 degraded 表示。
    点検不能項目は `unknown` 表示。`exit 0` を維持（read-only / 線形以下 / 数秒以内）
  - `issue-watcher.sh` に Config ブロック ＋ module source 完了後・flock 取得（L578）の前に
    `case "${1:-}" in --doctor) sh_doctor_run; exit $?;; esac` を挿入（full cycle に入らず終了）
  - _Requirements: 4.1, 4.6, 4.7, 5.3, NFR 3.1, NFR 4.1, NFR 5.1_
  - _Boundary: issue-watcher.sh, scaffolding-health.sh_
  - _Depends: 3.1_

- [ ] 4. README を更新し挙動変更を二重管理として反映
- [ ] 4.1 README に Scaffolding Health Gate / doctor の節と env を追記
  - 「オプション機能（標準有効 / 常時有効）一覧」節に `SCAFFOLDING_HEALTH_HALT`（既定 `off`=可視化
    のみ）を追記
  - 新規節「Scaffolding Health Gate / doctor (#238)」を追加: preflight gate の挿入位置・既定可視化
    挙動・HALT opt-in 仕様・fail-open 仕様・`issue-watcher.sh --doctor` の起動構文（REPO/REPO_DIR を
    env で渡す）・レポート書式・read-only 保証・tracked repo NO-OP（false positive 0 件）を記述
  - _Requirements: 2.1, 2.3, 4.1, 4.6, 5.2_

- [ ]* 5. 検査・doctor の境界スモークテスト fixture を追加
  - `docs/specs/238-feat-watcher-scaffolding-health-gate-wor/test-fixtures/` に full/missing/empty/
    indeterminate worktree fixture と `sh_inspect_scaffolding` / HALT 値正規化を検証する
    スモークスクリプトを追加し、本 spec 実装後の回帰確認に使う
  - _Requirements: 1.1, 1.5, 2.3, 3.1, 5.1_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下の
構造化ブロックで宣言する。本 Issue は shellcheck で静的検証可能なので、本体と全モジュール
（新規 `scaffolding-health.sh` を含む）を shellcheck にかける。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh
```
