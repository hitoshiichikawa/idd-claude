# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T12:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-168-impl-bug-watcher-macos-brew-install-coreutils
- HEAD commit: 610d36f8dad1efc7a3e566637f60c0fa0beeac1f（実装本体 d5dfb7c / impl-notes 9fed857 / spec docs 610d36f）
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/issue-watcher.sh`（+30 行）, `README.md`（macOS 依存節 + Phase A migration note）, `docs/specs/168-.../requirements.md`, `impl-notes.md`, `review-notes.md`

## Feature Flag Protocol 採否確認

- 対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節は **存在しない**
  （`.claude/rules/` 一覧表に `feature-flag.md` の行があるのみで、採否宣言節は不在）。
  → **opt-out 扱い**（既定 / Req 1.3）。flag 観点の細目は適用せず、通常の 3 カテゴリ判定のみを実施した。

## tasks.md / design.md の不在について

- 本 Issue は bug 修正で Architect ステージを経ておらず、`tasks.md` / `design.md` は存在しない。
  したがって `_Boundary:_` アノテーションは無い。boundary 逸脱判定は「変更ファイルが Issue
  スコープと整合するか」に基づき実施した（後述「Boundary 確認」参照）。

## Verified Requirements

- 1.1 — `issue-watcher.sh:453` の `timeout()` シェル関数定義。timeout 不在 / gtimeout 存在時に `timeout` 呼び出しが gtimeout に解決されることを **独立スモークで再現確認**（`command -v timeout -> timeout`、各呼び出しが `GTIMEOUT_CALLED`）
- 1.2 — `issue-watcher.sh:467-471` の専用チェック。フォールバック関数定義後は `command -v timeout` が function として true を返し前提チェックを通過（独立スモークで `command -v timeout -> timeout` を確認）
- 1.3 — フォールバック定義（`:453`）が前提ツールチェックループ（`:460` の `for cmd in gh jq claude git flock`）および timeout 専用チェック（`:467`）より前に配置されていることを行番号で確認（453 < 460 < 467）
- 2.1 — コマンド置換 `$(timeout 5 echo X)` が `GTIMEOUT_CALLED args=5 echo X` に解決（独立スモークで確認）
- 2.2 — サブシェル `( ... )` およびバックグラウンド fork `( ... ) &` がいずれも gtimeout に解決（独立スモークで両者とも `GTIMEOUT_CALLED` を確認。シェル関数は fork した子シェルへ継承される）
- 2.3 — `bash -c "timeout 5 echo X"` が gtimeout に解決（`export -f timeout` の効果。独立スモークで `GTIMEOUT_CALLED args=5 echo X` を確認）
- 2.4 — `--kill-after=10` 等のオプションが `"$@"` 透過で gtimeout にそのまま引き渡される（独立スモークで `args=--kill-after=10 5 echo X` を確認）
- 3.1 — `issue-watcher.sh:467-471` の専用チェックが両不在時に stderr へ「timeout コマンドが見つかりません」を出力（独立スモークで確認）
- 3.2 — 同チェックが `exit 1`（非ゼロ）で終了（独立スモークで `exit_code=1` を確認）
- 3.3 — エラーメッセージに「macOS では 'brew install coreutils' で gtimeout を導入すると自動検出されます」を含む（`issue-watcher.sh:469`、独立スモークで確認）
- 4.1 — `README.md` macOS 依存節（前提条件）および Phase A migration note に `timeout` 不在時の gtimeout 自動検出フォールバック・手動シンボリックリンク不要の旨を記載（diff で確認）
- 4.2 — `README.md` の両箇所に `brew install coreutils` 案内を記載（diff で確認）
- NFR 1.1 — `timeout` 存在時はフォールバック関数を定義しない（独立スモークで `type -t timeout = file`、関数未定義を確認）
- NFR 1.2 — diff は新規 timeout フォールバックブロック + 専用チェックの追加のみで、既存ロジックの書き換えはない。共通前提チェックループから `timeout` を外した点は、専用チェックで等価以上のチェック（function 判定込み）を継続しており起動可否・exit code・ログ出力契約を破壊しない
- NFR 1.3 — env var rename が diff に含まれないことを `grep -E "TIMEOUT|REPO|LOG_DIR|LOCK_FILE"` で確認（`no env var changes`）。`MERGE_QUEUE_GIT_TIMEOUT` 等の既存変数名は不変
- NFR 2.1 — gtimeout はフォールバック条件（timeout 不在かつ gtimeout 存在）の `if` ガード内でのみ参照。新規必須依存を増やさない

## Boundary 確認（追加観点）

- 変更ファイルは `local-watcher/bin/issue-watcher.sh`（フォールバック実装）と `README.md`
  （Req 4 のドキュメント化）に限定され、いずれも Issue #168 のスコープ（macOS gtimeout
  フォールバック + その明文化）と整合する。Out of Scope（install.sh / setup.sh の自動導入、
  GitHub Actions 側、汎用 g- プレフィックス対応）への手出しは無い
- `verify_pushed_or_retry` および Stage C verify ヘルパーの `command -v timeout` 分岐は
  **実行時評価**であり、ロード時のフォールバック関数定義より後に評価される。macOS では
  function 判定で `(timeout 30)` 経由（実体 gtimeout）になり Req 2 の方向と整合、Linux では
  file 判定で挙動不変。順序問題なし
- exit code 意味 / cron 登録文字列 / ラベル遷移契約 / 既存 env var 名のいずれにも変更なし。
  silent fail は作っていない（両不在時は stderr + 非ゼロ exit で停止 / Req 3）

## missing test 確認

- 本リポジトリは unit test フレームワークを持たず、手動スモークが検証手段（CLAUDE.md
  「テスト・検証」節が判定の正本）。impl-notes 記載の Scenario 1〜3 + dry run が全 AC を
  観測可能な形でカバーしている
- Reviewer 側でも独立に Scenario 1（コマンド置換 / サブシェル / bg fork / オプション付き /
  bash -c の全パス）・Scenario 2（NFR 1.1）・Scenario 3（Req 3.1/3.2/3.3）を再実行し、
  AC ごとの観測挙動を裏取りした。加えて `bash -n`（SYNTAX_OK）と `shellcheck -S warning`
  （警告ゼロ）も確認。検証根拠の欠落は無い

## Findings

なし

## Summary

Requirement 1〜4 / NFR 1〜2 の全 numeric AC が実装でカバーされ、Reviewer 独立スモークテストで
AC ごとの観測可能な挙動（gtimeout 解決 / 既存環境での非定義 / 両不在時の明示エラー）を再現
確認した。boundary 逸脱・env var / exit code 後方互換の破壊・silent fail・missing test は
いずれも検出されず、Linux 既存環境での挙動不変も確認できた。

RESULT: approve
