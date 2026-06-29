# Implementation Plan

- [x] 1. 新 env gate の config 追加と起動時正規化（issue-watcher.sh）
  - Phase D 設定ブロック（`issue-watcher.sh` L374〜407 付近）に `AUTO_REBASE_ADDITIVE`（既定 `off`、`case` で `claude` 以外/不正値を `off` 正規化）を追加
  - `AUTO_REBASE_ADDITIVE_PATHS`（既定空、カンマ区切り bash glob、`MECHANICAL_PATHS` と同構文）を追加
  - `process_auto_rebase` のサイクル開始ログ（L1289 付近）に `additive=` 解決値を併記（NFR3.1 可観測性の起点）
  - 既存「デフォルト有効化フラグ正規化」ループには含めない（既定 OFF opt-in のため `AUTO_REBASE_MODE` と同扱い）
  - `bash -n` / `shellcheck` クリーンを確認
  - _Requirements: 1.1, 1.2, 1.3, 1.4, NFR1.2_

- [ ] 2. 加算的判定の純粋関数 ar_classify_additive を新設（auto-rebase.sh）
  - `ar_classify_additive`（純粋・トップレベル副作用なし・`ar_` prefix）を追加。env は遅延束縛参照で `extract_function` 抽出可能に保つ
  - gate OFF → `not-additive`/`gate-off`、paths 空 → `not-additive`/`paths-empty` を返す（Req 1.1, 1.4）
  - `git diff --name-only base..head` で全 path が `AUTO_REBASE_ADDITIVE_PATHS` glob に閉じるか照合、逸脱 → `not-additive`/`path-out`（Req 2.3）
  - unified hunk を走査し `-` 行（`---` ファイルヘッダ除外）を 1 つでも検出 → `not-additive`/`non-additive-hunk`、rename/mode/binary も安全側除外（Req 2.2, NFR2.2）
  - `git diff` 非0/取得失敗 → `not-additive`/`diff-failed` + return 1（Req 2.4, NFR2.1）
  - 全 path 閉 + 全 hunk 追加のみ → `additive` + `ar_log` で根拠記録（Req 2.1, 2.5, NFR3.1）
  - ファイル冒頭の関数一覧コメント（L13〜15）へ `ar_classify_additive` を追記
  - 同 task 内テスト: `local-watcher/test/ar_additive_test.sh` を新設し、`docs/specs/.../test-fixtures/` の diff fixture（追加のみ / 削除含む / path 逸脱）を用いて `extract_function` で隔離抽出 + `git`/`ar_log` stub で 6 ケース（gate-off / paths-empty / additive / non-additive-hunk / path-out / diff-failed）を検証（safety-side fallback / failure path のため同 task 内テスト必須）
  - _Requirements: 1.1, 1.4, 2.1, 2.2, 2.3, 2.4, 2.5, NFR2.1, NFR2.2, NFR3.1_
  - _Boundary: ar_classify_additive_

- [ ] 3. ar_classify_diff への二次判定フック挿入（auto-rebase.sh）
  - `ar_classify_diff` の `first_unmatched` 検出後 `echo "semantic"` する手前（L350 付近）に gate ON 判定を挟む
  - gate ON 時のみ `ar_classify_additive` を呼び、`additive` なら `echo "mechanical"` + 根拠ログ、それ以外は従来 `semantic`（Req 1.2, 2.5）
  - gate OFF（既定）では二次判定を一切呼ばず stdout/ログとも導入前と同一（Req 1.1, NFR1.1）
  - `MECHANICAL_PATHS` 全一致経路は不変であることを確認（NFR1.3）
  - 既存 stdout 契約（1 行目 mechanical|semantic / 2 行目 unmatched）を維持し、加算的昇格時は 1 行目 `mechanical`
  - 加算的昇格時は `ar_handle_pr` の既存 `classification == "mechanical"` 分岐（L1200）へ流れ、既存 `ar_apply_mechanical`（needs-rebase 除去のみ・approve 維持・コメントなし）を再利用することで副作用同一性・必須 status check 迂回なし・semantic 副作用不起動を構造的に保証（新規副作用コードは追加しない / Req 3.1, 3.2, 3.3）
  - 同 task 内テスト: `ar_additive_test.sh` に `ar_classify_diff` 抽出での結線検証を追加（gate OFF で従来 semantic / `MECHANICAL_PATHS` 全一致で従来 mechanical / gate ON 加算的成立で mechanical 昇格 → 既存 mechanical 経路へ。behavior-changing task のため regression を同 task 内に含む）
  - _Requirements: 1.1, 1.2, 1.3, 2.5, 3.1, 3.2, 3.3, NFR1.1, NFR1.3_
  - _Boundary: ar_classify_diff, ar_classify_additive_
  - _Depends: 2_

- [ ] 4. self-register 指針を design-principles.md に追記（root + repo-template byte 一致）
  - `.claude/rules/design-principles.md` の「File Structure Plan の書き方」節と「参考」節の間に新節 `## bootstrap 一極集中の回避（self-register パターン）` を追加（canonical）
  - 内容: bootstrap 一極集中の merge conflict ホットスポット課題（Req 4.1）/ self-register（registry）回避指針の提示（Req 4.1, 4.2）/ 複数ドメインが加算的追記を検討する場合の評価対象提示（Req 4.2）/ 強制レベルは **推奨**で誤読されない明示（Req 4.3、冒頭 1 文で宣言）。コードテンプレートは置かない（Out of Scope）
  - `repo-template/.claude/rules/design-principles.md` に同一内容を byte 一致反映（Req 5.1）
  - `diff -r .claude/rules repo-template/.claude/rules` が差分ゼロであることを確認（Req 5.2）
  - _Requirements: 4.1, 4.2, 4.3, 5.1, 5.2_
  - _Boundary: design-principles.md_
  - _Depends: 1_

- [ ] 5. README「Auto Rebase Processor (Phase D)」節へ新 env gate / 分類表 / migration note 追記
  - 環境変数表（L1896 付近）に `AUTO_REBASE_ADDITIVE`（既定 `off`）/ `AUTO_REBASE_ADDITIVE_PATHS`（既定空）を追加し、既定 no-op と安全側正規化を migration note として明記（NFR4.1）
  - 動作フロー表（L1888 付近）に「加算的 mechanical 昇格」行（条件: gate ON + bootstrap allowlist 閉 + 全 hunk 追加のみ / 副作用: 既存 mechanical と同一）を追記（Req 3.1）
  - 加算的判定の構文的限定（追加のみ・削除/変更なし・取得失敗時は semantic）と merge-queue scope 外を 1〜2 文で補足
  - _Requirements: NFR4.1_
  - _Depends: 1_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
bash -n local-watcher/bin/issue-watcher.sh &&
  shellcheck local-watcher/bin/modules/auto-rebase.sh local-watcher/bin/issue-watcher.sh &&
  bash local-watcher/test/ar_additive_test.sh &&
  diff -r .claude/rules repo-template/.claude/rules
```
