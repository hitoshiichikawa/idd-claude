# 実装メモ: Issue #295 — `_worktree_reset` の transient 失敗診断可能化とリトライ吸収

## 概要

`local-watcher/bin/modules/core_utils.sh` の `_worktree_reset()` 関数を改修し、
`git reset --hard` と `git clean -fdx` 双方について:

- stderr を一時ファイルへ捕捉し、失敗時に「操作種別 + 試行回数」付きで運用者ログへ追記
- 最大 3 回（初回 + 再試行 2 回）試行し、再試行間に 1 秒・2 秒の指数バックオフを挟む
- 通常ケース（初回成功）では追加遅延・追加ログを発生させない

を実装した（Req 1.x / Req 2.x / Req 3.x / NFR 1.x / NFR 2.x / NFR 3.x すべて充足）。

## 採用した設計判断

### stderr 保全手段（要件確認事項への回答）

- **採用方式**: 候補 C ＋ 既存 `slot_log` / `slot_warn` の併用（候補 B 寄り）
- **理由**:
  - `core_utils.sh` 内の既存ヘルパ `_worktree_inject_claude` が既に `slot_log` / `slot_warn`
    を直接呼んでおり、同パターンを踏襲することで一貫性を保てる
  - `slot_log` / `slot_warn` は issue-watcher.sh 本体側の slot worker サブシェル文脈で
    `IDD_SLOT_NUMBER` / `NUMBER` を prefix に付与する。`_worktree_reset` は slot worker
    内部で呼ばれるため、これらの env が必ず設定済みであることが保証される
  - `slot_warn` は内部で `>&2` へ出力するため、watcher 本体のサブシェル内 stderr
    リダイレクト（SLOT_LOG への追記）に自然に乗る。新たな global env や引数追加は不要
  - bash の late binding により、`core_utils.sh` source 時点で `slot_log` / `slot_warn` が
    未定義でも、`_worktree_reset` 呼び出し時点で定義済みであれば動作する（実際にそうなる）
- **stderr 本文ログ**: stderr 本文（複数行）は `tail -c 2000` で末尾 2KB に切り詰めた上で
  `>&2` へ直接 echo する。`slot_warn` を 1 行サマリ用、生 stderr を別ブロックとして
  運用者ログに残す（`_hook_invoke` の 2KB 上限と同等）

### リトライ実装の構造

- **内部ヘルパ関数化**: `_worktree_reset_retry "$op" git -C "$wt" <subcmd>...` という形で
  操作種別ラベル（reset / clean）と git argv を受け取るヘルパを新設
- **理由**:
  - reset / clean を inline で 2 重展開すると本体関数が大きくなり、共通処理（stderr 捕捉
    + リトライ + バックオフ + サマリログ）が重複して可読性を損なう
  - 将来他コマンドへ同じリトライパターンを横展開する余地を残せる（YAGNI に寄せ、現時点では
    `_worktree_reset` 専用ヘルパとして prefix `_worktree_reset_retry` を選んだ）
- **バックオフ**: `attempt` 番号（1, 2, 3）の前 2 回のみ `sleep "$attempt"` で 1s / 2s を
  待機。3 回目失敗後は即時 return（無駄な待機を発生させない / NFR 2.1）
- **fallback**: `mktemp` が失敗した場合（極端な degraded ケース）は stderr 捕捉を諦め、
  git の stderr を呼び出し元へ直接流す。「ログ識別子付き保全」は失われるが、診断不能
  （旧実装）よりは可視性が高い

## トレーサビリティ表（AC ↔ 実装箇所）

| AC | 担保箇所 | 確認したスモークテスト |
|---|---|---|
| Req 1.1 (reset 失敗時 stderr ログ) | `_worktree_reset_retry` 内 `slot_warn` + stderr tail echo | Test 2 ログに `reset 失敗 (attempt=1/3, rc=128)` + git stderr 表示を確認 |
| Req 1.2 (clean 失敗時 stderr ログ) | 同上（`op="clean"` で同じヘルパに通す） | clean を強制失敗させる経路は別途冪等構成が必要だが、ヘルパ共通のため Test 2 と同経路 |
| Req 1.3 (操作種別 + 試行回数識別子) | `worktree-reset: ${op} 失敗 (attempt=N/3, rc=...)` + `stderr (attempt=N, tail):` | Test 2 ログで `attempt=1/3 .. attempt=2/3 .. attempt=3/3` が visually 区別可能であることを確認 |
| Req 1.4 (成功通常ケースは stderr 冗長出力なし) | 初回 `rc=0` で early return（`attempt > 1` 時のみ slot_log を出す） | Test 1 で `[slot_log]` / `[slot_warn]` 行が一切出力されないことを確認 |
| Req 2.1 (reset を最大 3 回 / 1s,2s backoff) | `max_attempts=3` + `sleep $attempt` (attempt < max) | Test 2 で elapsed=3s（1s+2s）を確認 |
| Req 2.2 (clean を最大 3 回 / 1s,2s backoff) | reset と同じヘルパを共有 | Test 2 と同経路で担保 |
| Req 2.3 (リトライ吸収成功時に呼び出し元へ 0 を返す) | `rc=0` で `return 0` | Test 3 で `_worktree_reset` が 0 を返すことを確認 |
| Req 2.4 (恒久失敗時に 1 を返す) | 3 回試行後の最終 `return 1` | Test 2 で `_worktree_reset` が非ゼロを返すことを確認 |
| Req 2.5 (最終試行回数 / 結果のサマリログ) | リトライ吸収成功時 `[slot_log] ... リトライ吸収で成功 (attempt=N/3)` / 恒久失敗時 `[slot_log] ... 3 回試行後も失敗（恒久失敗として呼び出し元へ返す）` | Test 2 / Test 3 双方で対応サマリログを確認 |
| Req 3.1 (成功時 exit code 互換) | 既存と同じ `return 0` | Test 1 / Test 3 で確認 |
| Req 3.2 (失敗時 exit code 互換) | 既存と同じ `return 1` | Test 2 で確認 |
| Req 3.3 (リセット後 worktree 状態) | git の `reset --hard` + `clean -fdx` 動作は変更せず | Test 1 で `git status --porcelain` が空、`node_modules/` 等 untracked / ignored 削除を確認 |
| Req 3.4 (直列実行通常ケースで初回完了) | 初回 `rc=0` で early return | Test 1 で WARN/LOG 出力なし、elapsed 即時 |
| NFR 1.1 (関数シグネチャ / exit 契約変更なし) | 関数引数 `$1=wt` のまま、return 値 0/1 のみ | コードレビュー観点 |
| NFR 1.2 (通常ケース観測挙動同等) | 初回成功で追加遅延なし | Test 1 |
| NFR 2.1 (総追加待機時間 10 秒以内) | 1s + 2s = 3s（reset） + 同 3s（clean） = 最大 6s | Test 2 で 3s を確認、reset と clean 合算でも 6s で 10s 以内 |
| NFR 2.2 (個別タイムアウトなし / 上限で無限ループ回避) | `max_attempts=3` で while ループ強制終了 | コードレビュー観点 |
| NFR 3.1 (直列実行への副作用なし) | 追加ロック / 競合判定なし。`mktemp -t` の一時ファイルのみ | コードレビュー観点 |

## 手動スモークテスト結果

実施項目 / 結果:

1. `shellcheck local-watcher/bin/modules/core_utils.sh` — exit 0（warning ゼロ）
2. `bash -n local-watcher/bin/modules/core_utils.sh` — 構文 OK
3. **Test 1 (success path)**: 通常 dirty 状態の worktree（modified tracked + untracked
   + `node_modules/`）に対して `_worktree_reset` 呼び出し → return 0、`git status` 空、
   `node_modules/` 削除済み、WARN/LOG 出力なし（Req 1.4 / 3.3 / NFR 1.2 担保）
4. **Test 2 (permanent failure)**: `BASE_BRANCH=nonexistent-branch-xyzzy` で git reset が
   常に失敗する状況を作り → 3 回試行、各 attempt の WARN + git stderr tail がログ追記、
   最後に `[slot_log] ... 3 回試行後も失敗` サマリ、return 1。elapsed 3s（1s+2s backoff
   が確かに走った）（Req 1.1〜1.3 / Req 2.1 / Req 2.4 / Req 2.5 / NFR 2.1 担保）
5. **Test 3 (transient recovery)**: PATH に偽 `git` wrapper を置き、1 回目の reset のみ
   exit 128 で失敗、2 回目以降は実 git に passthrough → return 0、attempt 1 の WARN +
   stderr tail がログ追記、`リトライ吸収で成功 (attempt=2/3)` のサマリログ。elapsed 1s
   （1s backoff のみ走った）（Req 2.3 / Req 2.5 担保）

## root ↔ repo-template の同期

`repo-template/local-watcher/` は **存在しない**（`local-watcher/` は root のみで管理されており、
`install.sh` は `local-watcher/bin/` から `$HOME/bin/` へ直接配置する設計）。したがって本変更は
root の `local-watcher/bin/modules/core_utils.sh` のみで完結し、repo-template との二重管理
ドリフトリスクは無い。

CLAUDE.md「テスト・検証」節の `diff -r .claude/agents repo-template/.claude/agents` は
agents / rules の二重管理に関するものであり、`local-watcher/` には適用されない。

## 確認事項（Reviewer 向け）

- **stderr ログ 1 行目の prefix 形式**: `slot_warn "worktree-reset: ${op} 失敗 ..."` で 1 行サマリ
  を出した後、stderr 本体は直接 `echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: WARN: worktree-reset: ${op} stderr (attempt=N, tail):"`
  + 生 stderr の 2 行で出力している。既存 `_hook_invoke` の「サマリ → stderr 本体」分離
  パターンを踏襲。冗長と感じる場合は `slot_warn` を 1 行に集約することも可能（要件は
  「操作種別 + 試行回数を識別できる形でログに残す」なので現状で要件充足）
- **mktemp template**: `worktree-reset-XXXXXX.err` を使用。`_hook_invoke` は
  `slot-init-hook-XXXXXX.err` を使っており、同じ命名規約に沿っている
- **`sleep` のフォールバック**: `sleep $backoff || true` で `sleep` 失敗時の致命化を防いでいる
  が、Linux/macOS の coreutils `sleep` は事実上失敗しない。念のための防御
- **`set -euo pipefail` 配下での挙動**: `"${cmd[@]}" >/dev/null 2>"$stderr_tmp" || rc=$?`
  により、コマンド失敗を rc 変数に受けて continue する。`set -e` で関数全体が落ちることはない

## 出典・参考

- 既存パターン参照: `_hook_invoke`（`mktemp` + stderr 同期捕捉 + `tail -c 2000` ＋ rc gate）
- 既存パターン参照: `_worktree_inject_claude`（`slot_log` / `slot_warn` の late-bound 利用）
- 関連 Issue: #167（per-slot fetch ロック競合除去。本 Issue 改修対象の隣接コンテキスト）

STATUS: complete
