# 要件定義: bug(watcher): _worktree_reset transient 失敗の診断可能化とリトライ吸収

## Overview

ローカル watcher の worktree リセット処理は、worktree を `origin/<BASE_BRANCH>` 最新かつ clean
な状態に戻すための前処理として、`git reset --hard` と `git clean -fdx` を実行する。現在の実装は
両コマンドの標準エラー出力を握り潰し、かつ一度でも非ゼロ終了したら即座に slot を失敗扱いに
落として対象 Issue に `claude-failed` ラベルを付与する。

この設計には 2 つの問題がある:

- **診断不能**: 失敗時に git の stderr が運用者に一切残らず、根本原因（EBUSY、I/O、ロック等）の
  事後追跡ができない
- **transient 失敗の偽陽性化**: 直前サイクルで生成された大量ファイル（例: frontend のビルド
  成果物）や、未終了の子プロセスが掴むファイルハンドル等、短時間で自然解消する transient
  要因による失敗が、恒久失敗と区別されず無実の Issue に `claude-failed` を付ける

2026-06-06 17:27 JST に実発生したケース（直列実行下にも関わらず worktree-reset が即失敗）でも、
事後検証時には失敗条件が完全に解消されており transient であることが確定したが、git stderr が
残っていないため一次原因の特定ができなかった。

本要件定義のゴールは以下:

- 失敗時に運用者が後追い可能な形で git の stderr をログへ保全する
- transient 失敗を短いリトライで吸収し、リトライ後も失敗した場合のみ恒久失敗として扱う
- 既存呼び出し元から見た exit code 契約、リセット後の worktree 状態、通常ケースの挙動を
  後方互換に保つ

スコープ外:

- per-slot fetch ref ロック競合（#167 で対応済み）の再対応
- frontend ビルド成果物そのものの生成抑制、および Claude セッション終了時の子プロセス
  reap 強化（別 Issue 候補）
- worktree-reset 以外の stage における stderr 取り扱い方針の一括見直し

## Requirements

### Requirement 1: worktree リセット失敗時の診断ログ保全

**Objective:** As a watcher 運用者, I want worktree リセット失敗時の git stderr が後追い可能な
ログに残ること, so that 偽陽性 `claude-failed` の根本原因を事後特定し再発防止策を判断できる

#### Acceptance Criteria

1. If worktree リセットの `git reset --hard` が非ゼロで終了したら, the Worktree Reset Module
   shall その実行に対応する git stderr 内容を運用者が後追い可能なログ（SLOT_LOG 等の
   watcher 標準ログ出力先）へ追記する
2. If worktree リセットの `git clean -fdx` が非ゼロで終了したら, the Worktree Reset Module
   shall その実行に対応する git stderr 内容を運用者が後追い可能なログへ追記する
3. When git stderr をログへ追記する, the Worktree Reset Module shall どの操作（reset か
   clean か）と何回目の試行に対応する stderr かを識別できる形でログに残す
4. While worktree リセットが成功裏に完了する通常ケース, the Worktree Reset Module shall
   git の stderr 内容を成功ログとして冗長に出力しない

### Requirement 2: transient 失敗のリトライ吸収

**Objective:** As a watcher 運用者, I want reset / clean の transient 失敗が短いリトライで自動的に
吸収されること, so that 自然解消する一時的失敗で無実の Issue に `claude-failed` が付かなくなる

#### Acceptance Criteria

1. If `git reset --hard` が非ゼロで終了したら, the Worktree Reset Module shall 最大 3 回まで
   試行（初回 + 再試行 2 回）し、再試行間に 1 秒・2 秒の指数バックオフを挟む
2. If `git clean -fdx` が非ゼロで終了したら, the Worktree Reset Module shall 最大 3 回まで
   試行（初回 + 再試行 2 回）し、再試行間に 1 秒・2 秒の指数バックオフを挟む
3. When リトライにより最終的に reset / clean が成功する, the Worktree Reset Module shall
   worktree リセット全体を成功として呼び出し元へ返す
4. If 最大試行回数を使い切ってもなお reset または clean が成功しなかったら, the Worktree
   Reset Module shall worktree リセットを恒久失敗として呼び出し元へ返す
5. When リトライ吸収または恒久失敗が確定する, the Worktree Reset Module shall 最終試行回数と
   最終結果（成功 / 恒久失敗）を運用者が後追い可能なログに残す

### Requirement 3: 後方互換な exit code 契約と worktree 状態保証

**Objective:** As 既存の watcher 呼び出し元, I want worktree リセット関数の exit code 契約と
リセット後の worktree 状態が従来と同一であること, so that 後方互換性を破らずに本修正を取り込める

#### Acceptance Criteria

1. When worktree リセットが（リトライ吸収を含み）最終的に成功する, the Worktree Reset
   Module shall 既存実装の成功時と同一の exit code を呼び出し元へ返す
2. When worktree リセットが恒久失敗として確定する, the Worktree Reset Module shall 既存
   実装の失敗時と同一の exit code 種別を呼び出し元へ返す
3. When worktree リセットが成功した直後の worktree, the Worktree Reset Module shall HEAD
   が `origin/<BASE_BRANCH>` の最新コミットを指し、かつ追跡外ファイルが残っていない clean
   な状態であることを保証する
4. While 直列実行（PARALLEL_SLOTS=1）で transient 失敗が発生しない通常ケース, the Worktree
   Reset Module shall リトライを発生させず初回試行のみで完了する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While 既存の watcher 呼び出し元が `_worktree_reset` 相当の関数を呼び出す, the Worktree
   Reset Module shall 関数シグネチャ（引数の有無・順序）と exit code 契約を破壊的に変更しない
2. While 直列実行（PARALLEL_SLOTS=1）かつ transient 失敗が発生しない通常ケース, the
   Worktree Reset Module shall 本修正導入前と等価な観測挙動（追加遅延なし、追加ログ行なし
   を除く運用上の差分なし）で完了する

### NFR 2: 総待機時間の上限

1. When transient 失敗が継続して恒久失敗として確定する, the Worktree Reset Module shall
   リトライ間バックオフによる総追加待機時間を 10 秒以内に収める（reset と clean を合算）
2. While リトライ吸収中, the Worktree Reset Module shall 個別の git コマンドにタイムアウトを
   設けないが、最大試行回数 3 回の上限により無限ループに陥らない

### NFR 3: 直列実行への影響なし

1. While 直列実行（PARALLEL_SLOTS=1）下で本修正が有効, the Worktree Reset Module shall
   他 slot との競合判定や追加ロック取得など、直列実行の所要時間を増やす副作用を導入しない

## Out of Scope

- per-slot fetch ref ロック競合の再対応（#167 で対応済み）
- frontend ビルド成果物（`node_modules/`, `.next/` 等）の生成自体を抑制する仕組み
- Claude セッション終了時の子プロセス reap 強化（残プロセスがファイルハンドルを掴み続ける
  根本原因の解消）
- worktree-reset 以外の stage（実装本体・PR 作成・review 等）における stderr 取り扱い
  方針の一括見直し
- リトライ回数・バックオフ秒数を環境変数で外部 override 可能にする機構（必要なら別 Issue で
  追加検討）

## 確認事項

- **stderr のログ転送手段**: SLOT_LOG が `_worktree_reset` 関数内から global env として
  直接参照可能か、あるいは引数で受け取る／一時ファイル経由で呼び出し元へ受け渡すかの選択は
  Developer 判断に委ねる（観測要件は「失敗時に git stderr が運用者後追い可能なログに残る」
  に統一）
- **リトライ回数・バックオフ秒数の外部 override**: 本 Issue では既定値（最大 3 回 / 1s,2s）を
  焼き込む方針とし、環境変数 override は Out of Scope とした。運用上の必要が生じた場合は
  別 Issue で追加検討する
- **clean 前の grace sleep**: Issue 本文の方針に従い、まずは純粋リトライ（バックオフ間に
  自然吸収）のみで対処する。リトライでも吸収できないケースが実運用で観測された場合は別途
  検討する
- **本修正が watcher コアモジュールに与える影響範囲**: 既存呼び出し元（watcher 本体・他 stage）
  の挙動を変えないことは NFR 1 で担保するが、変更モジュールの単体スモークテスト方針は
  Architect / Developer 判断に委ねる

## 関連

- Related: #167
