# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-168-impl-bug-watcher-macos-brew-install-coreutils
- HEAD commit: 9fed857（実装本体 d5dfb7c / impl-notes 9fed857）
- Compared to: 7f6c99e..HEAD
- 変更ファイル: `local-watcher/bin/issue-watcher.sh`（+30 行）, `README.md`（macOS 依存節 + Phase A migration note）, `docs/specs/168-.../impl-notes.md`

## Feature Flag Protocol 採否確認

- `CLAUDE.md` に `## Feature Flag Protocol` 節は存在しない → **opt-out 扱い**（既定）。
  flag 観点の細目は適用せず、通常の 3 カテゴリ判定のみを実施した（Req 4.2 / NFR 1.1 準拠）。

## Verified Requirements

- 1.1 — `issue-watcher.sh:451-455` の `timeout()` シェル関数定義。timeout 不在 / gtimeout 存在時に `timeout` 呼び出しが gtimeout に解決されることを独立スモークで確認（`GTIMEOUT_CALLED`）
- 1.2 — `issue-watcher.sh:470-474` の専用チェック。フォールバック関数定義後は `command -v timeout` が function として true を返し前提チェックを通過（独立スモークで `command -v timeout -> timeout` を確認）。impl-notes の dry run でも前提チェック通過を確認
- 1.3 — フォールバック定義（`:451`）が前提ツールチェックループ（`:457` の `for cmd in gh jq claude git flock`）および timeout 専用チェック（`:470`）より前に配置されている（行順で確認）
- 2.1 — コマンド置換 `$(timeout ...)` が gtimeout に解決（独立スモークで `GTIMEOUT_CALLED`）
- 2.2 — サブシェル `( ... )` およびバックグラウンド fork `( ... ) &` が gtimeout に解決（独立スモークで両者とも `GTIMEOUT_CALLED`。シェル関数は fork した子シェルへ継承される）
- 2.3 — `bash -c` 経由の子 bash で `timeout` が gtimeout に解決（`export -f timeout` の効果。独立スモークで `bash -c "timeout 5 echo BASHC"` -> `GTIMEOUT_CALLED args=5 echo BASHC` を確認）
- 2.4 — `--kill-after=10` 等のオプションが `"$@"` 透過で gtimeout にそのまま引き渡される（独立スモークで `args=--kill-after=10 5 echo X` を確認）
- 3.1 — `issue-watcher.sh:470-474` の専用チェックが両不在時に stderr へ「timeout コマンドが見つかりません」を出力（独立スモークで確認）
- 3.2 — 同チェックが `exit 1`（非ゼロ）で終了（独立スモークで `exit_code=1` を確認）
- 3.3 — エラーメッセージに「macOS では 'brew install coreutils' で gtimeout を導入すると自動検出されます」を含む（`issue-watcher.sh:472`、独立スモークで確認）
- 4.1 — `README.md` macOS 依存節（前提条件）および Phase A migration note に `timeout` 不在時の gtimeout 自動検出フォールバックを記載（diff で確認）
- 4.2 — `README.md` の両箇所に `brew install coreutils` 案内を記載（diff で確認）
- NFR 1.1 — `timeout` 存在時はフォールバック関数を定義しない（独立スモークで `type -t timeout = file`、関数未定義を確認）
- NFR 1.2 — 既存環境での起動可否・exit code・ログ出力は不変。diff は新規 timeout ブロックの追加のみで、既存ロジックの書き換えはない（追加された `exit` は新エラーパスの `exit 1` のみで、既存前提チェックの慣習に一致）
- NFR 1.3 — env var 名（`MERGE_QUEUE_GIT_TIMEOUT` / `STAGE_A_VERIFY_TIMEOUT` / `STAGEC_VERIFY_TIMEOUT_SECS` 等）の変更なし（diff に env var rename を含まないことを確認）
- NFR 2.1 — gtimeout はフォールバック条件（timeout 不在かつ gtimeout 存在）でのみ利用。新規必須依存を増やさない（`if` ガードで確認）

## Boundary 確認（追加観点）

- `verify_pushed_or_retry`（`issue-watcher.sh:8561` 定義、`:8570` で `command -v timeout` 分岐）および `verify_stagec_pr_or_retry`（`:8702` 定義、`:8714` で分岐）は **関数本体内の実行時評価** であり、フォールバック関数定義（`:451`、スクリプトロード時）より後に評価される。順序問題なし
- macOS（timeout 不在 / gtimeout あり）ではこれらヘルパーが `command -v timeout` を function として true 判定し `(timeout 30)` 経由（実体 gtimeout）になる。これは Req 2（全パスで有効）の方向と整合する望ましい変化。Linux では従来通り file として true を返し挙動不変
- exit code 意味 / cron 登録文字列 / ラベル遷移契約 / 既存 env var 名のいずれにも変更なし。silent fail は作っていない（両不在時は stderr + 非ゼロ exit で停止 / Req 3）

## missing test 確認

- 本リポジトリは unit test フレームワークを持たず、手動スモークが検証手段（CLAUDE.md「テスト・検証」節）。impl-notes 記載の Scenario 1〜3 + dry run が全 AC を観測可能な形でカバーしている
- Reviewer 側でも Scenario 1（全 timeout 呼び出しパス: コマンド置換 / サブシェル / bg fork / オプション付き / bash -c）・Scenario 2（NFR 1.1）・Scenario 3（Req 3.1/3.2/3.3）を独立再実行し、AC との対応を裏取りした。検証根拠の欠落は無い

## Findings

なし

## Summary

Requirement 1〜4 / NFR 1〜2 の全 AC が実装でカバーされ、独立スモークテストで AC ごとの観測可能な挙動を再現確認した。boundary 逸脱・env var / exit code 後方互換の破壊・silent fail はいずれも検出されず、Linux 既存環境での挙動不変も確認できた。

RESULT: approve
