# 実装ノート（#246）

## 変更点サマリ

`local-watcher/bin/modules/stage-a-verify.sh` の round counter 永続化先を **worktree 外**へ移した。

- **`stage_a_verify_round_path()`**: 旧 `$REPO_DIR/$SPEC_DIR_REL/.stage-a-verify-round`（worktree 配下＝
  毎サイクルの `git clean -fdx` で消える）を、worktree 外の state dir 配下
  `<state_dir>/<NUMBER>-<sanitized-branch>.stage-a-verify-round` へ変更した。
- **新規ヘルパ `_sav_state_dir()`**: 永続化先ベースディレクトリを返す。既定は LOG_DIR と同流儀の
  `$HOME/.issue-watcher/state/$REPO_SLUG`。新規 optional env var `STAGE_A_VERIFY_STATE_DIR` で上書き可能。
  `REPO_SLUG` 未設定時は `REPO`（owner/name）から `tr '/' '-'` で防御的に派生し、それも無ければ
  `_unknown` にフォールバック（silent fail 回避 / CLAUDE.md 規約）。
- **新規ヘルパ `_sav_round_key()`**: Issue 番号 + branch でファイル名を一意化するキーを返す。
  `$NUMBER` + サニタイズした `$BRANCH`。`BRANCH` 不在時は `SLUG`、それも無ければ `SPEC_DIR_REL` の
  basename へフォールバック。`tr -c 'A-Za-z0-9._-' '-'` で `/` 含む非許可文字を `-` へサニタイズ。

`read` / `bump` / `reset` / `_sav_handle_failure` / `stage_a_verify_run` はいずれも path 生成を
`stage_a_verify_round_path()` に集約しているため、当該 1 関数の差し替えで全経路へ波及する
（grep で path 直書き参照が無いことを確認済み）。`bump` の `mkdir -p "$(dirname "$path")"` が
新 state dir を自動作成するため、生成ロジックの追加は不要。

`_sav_source_path()`（`.stage-a-verify-source` sidecar）は **変更していない**。これは resolve→run の
同一 tick 内でサブシェル境界を越えるためだけに使われ、worktree reset 前に読み終わるため移動不要
（Out of Scope と整合）。

## 永続化先の最終決定

- **パス scheme**: `${STAGE_A_VERIFY_STATE_DIR:-$HOME/.issue-watcher/state/<repo_slug>}/<NUMBER>-<sanitized-branch>.stage-a-verify-round`
- **一意化キー**: Issue 番号 (`$NUMBER`) + branch (`$BRANCH`、`/` を `-` へサニタイズ)。repo 分離は
  state base に含まれる `<repo_slug>` が担保。slot 分離は branch（slot ごとに異なる worktree が同一
  branch を持つことはない運用前提だが、branch 一意化により衝突しない）。
- **新規 env var の有無と理由**: 新規 optional env var `STAGE_A_VERIFY_STATE_DIR` を **追加した**。
  理由は (1) テスト容易性（fixture が一時ディレクトリへ redirect できる）、(2) 隔離・移設の運用余地。
  既定値付き・既存 env var 名と非衝突のため CLAUDE.md「既存 env var 名を壊さない」の趣旨に反しない。
  HOME override 案も検討したが、REPO_SLUG 派生・LOG_DIR 等が HOME に依存する副作用が大きく、
  state dir 専用 env の方が影響範囲が局所的で安全と判断した。

## テスト内容と実行結果

新規 fixture: `docs/specs/246-bug-watcher-stage-a-verify-round-counter/test-fixtures/test-round-counter-persistence.sh`
（モジュールを source し round counter 関数を直接呼ぶ。既存 `test-design-less-skip.sh` のパターンに準拠）。

検証ケース:

- **core 回帰**: bump で round=1 → worktree dir を `rm -rf`（worktree reset 相当）→ read が **1** を返す
  （リセットされない）→ 再 bump で round=**2**（escalate 到達）。旧実装ではここで read=0 → 再 bump=1 の
  無限 round=1 ループになることを別途スクリプトで確認済み。
- round_path が STATE_DIR（worktree 外）配下を指し WORKTREE 配下を指さないこと。
- 一意化: 異なる NUMBER / 異なる BRANCH / 異なる REPO_SLUG で round_path が異なる。BRANCH の `/` が
  サニタイズされ basename に `/` を含まない。デフォルト state base が `$HOME/.issue-watcher/` 配下。
- reset の冪等性: 不在に対する 2 回 reset でもエラーにならず read=0。
- 書き込み失敗時の安全側: 書き込み不能パスで bump が return 1、read は 0 のまま（差し戻し挙動へ倒れる）。

実行結果（PASS 要約）:

```
PASS=15 FAIL=0
TEST_EXIT=0
```

全 15 ケース PASS。

## shellcheck 結果

- `shellcheck local-watcher/bin/modules/stage-a-verify.sh` → クリーン（警告ゼロ）
- `shellcheck docs/specs/246-bug-watcher-stage-a-verify-round-counter/test-fixtures/test-round-counter-persistence.sh` → クリーン

## 後方互換性の担保

- **成功通常ケース不変（NFR 1.1）**: SUCCESS 時は counter を判定に使わず `stage_a_verify_reset_round` を
  呼ぶだけ。外形挙動は不変。
- **無効化不変（NFR 1.2）**: `STAGE_A_VERIFY_ENABLED=false` の DISABLED 経路は counter に一切触れず不変。
- **env var 名 / exit code / ラベル遷移 / ログ書式不変（NFR 1.3）**: 既存 env var 名は変更せず新規追加のみ。
  `stage_a_verify_run` の戻り値 (0/1/2)、`_sav_handle_failure` のラベル遷移契約（round=1 差し戻し /
  round=2 mark_issue_failed）、`sav_log`/`sav_warn`/`sav_error` のログ書式はいずれも不変。
- **round=0 解釈（NFR 1.4）**: 永続化先不在は `stage_a_verify_read_round` が "0" を返す既存挙動を維持。
  新永続化先に counter が無い既存 Issue は round=0（未失敗）として安全に解釈され、次サイクル以降で
  自然収束する（retrofit 不要）。

## AC との対応

- **Req 1.1（worktree reset を挟んだ再失敗で round=2 でエスカレーション）**: core 回帰テスト
  「worktree reset 後 bump → round=2」でカバー。
- **Req 1.2（初回失敗 round=1）**: 「初回 bump → round=1」テストでカバー。
- **Req 1.3（round>=2 でエスカレーション）**: `_sav_handle_failure` の round>=2 → mark_issue_failed(return 2)
  経路は不変。round が 2 へ到達できるようになったことを core 回帰テストで担保。
- **Req 1.4（リセットせず単調増加）**: 「worktree reset 後 read=1 → bump=2」でカバー。
- **Req 2.1（worktree reset で消えない場所に永続化）**: round_path が STATE_DIR / `$HOME/.issue-watcher/`
  配下で WORKTREE 配下を指さないことのテストでカバー。
- **Req 2.2（reset を跨いで直前 round を読める）**: 「worktree reset 後 read=1」でカバー。
- **Req 2.3（書き込み失敗時に round=1 相当へ安全側に倒れる）**: 書き込み不能時 bump return 1 / read=0 の
  テストでカバー。`_sav_handle_failure` は bump 失敗時も read=0→（次回失敗で +1）で差し戻し挙動へ倒れる
  既存設計を維持。
- **Req 3.1（Issue 番号 + branch で一意化）**: 異なる NUMBER / BRANCH で round_path が異なるテストでカバー。
- **Req 3.2（並行 Issue が独立に読み書き）**: NUMBER/BRANCH 一意化により path が分離されることで担保
  （上記テスト）。
- **Req 3.3（slot/repo 跨ぎで共有しない）**: 異なる REPO_SLUG で round_path が異なるテストでカバー。
- **Req 4.1（成功時 reset）**: `stage_a_verify_run` SUCCESS 経路の `stage_a_verify_reset_round` 呼び出しは不変。
  reset 後 read=0 テストでカバー。
- **Req 4.2（escalate 後 reset）**: `_sav_handle_failure` の escalate 経路の reset 呼び出しは不変。
- **Req 4.3（reset の冪等性）**: 不在に対する 2 回 reset テストでカバー。
- **NFR 1.1〜1.4**: 「後方互換性の担保」節記載。
- **NFR 2.1/2.2（読み出し副作用なし / reset 冪等）**: read を繰り返しても値が変わらないこと・reset 冪等
  テストでカバー。
- **NFR 3.1（round 値と遷移結果をログ出力）**: `_sav_handle_failure` の `sav_log "round=... outcome=..."`
  は不変。
- **NFR 4.1（README 更新）**: README「Stage A Verify Gate (#125)」節・env var 表・オプション機能一覧を
  同一コミットで更新。

## 確認事項

- なし。永続化先の具体パス・env var 名は requirements.md の Out of Scope（design.md の領分）で
  Developer 裁量に委ねられており、上記方針（state dir 専用 optional env var + REPO_SLUG/branch 一意化）で
  確定した。レビュワー判断ポイントは「新規 env var `STAGE_A_VERIFY_STATE_DIR` の追加可否」だが、
  既定値付き・既存名非衝突であり CLAUDE.md 規約に整合する。

## Implementation Notes

### Task （design-less impl / 単一実装）

- 採用方針: round counter の永続化先を `stage_a_verify_round_path()` 1 関数に集約された path 生成を
  worktree 外（`$HOME/.issue-watcher/state/<repo_slug>`）へ差し替え、Issue 番号 + branch で一意化。
- 重要な判断: 新規 optional env var `STAGE_A_VERIFY_STATE_DIR` を導入（テスト容易性と既存名非衝突の両立）。
  HOME override 案は副作用が広いため不採用。source sidecar は同一 tick 内利用のため移動不要（Out of Scope）。
- 残存課題: なし。

STATUS: complete
