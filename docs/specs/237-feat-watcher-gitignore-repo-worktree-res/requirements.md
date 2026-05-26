# Requirements Document

## Introduction

idd-claude の watcher は slot worktree を毎サイクル `origin/<base>` へ強制リセット（`git reset --hard` ＋ `git clean -fdx`）してから agent を起動する。`.claude/` を gitignore して足場を public repo に出さない運用の consumer repo では、`.claude/` が commit されないため reset 後の worktree に `.claude/agents` `.claude/rules` が現れず、agent がルール・定義を読めない degraded 状態になる。

本機能は、worktree reset 直後に REPO_DIR のローカル `.claude/`（`install.sh` が管理するコピー）を worktree へ注入する経路を追加し、gitignore 運用 repo でも agent runtime が必要な `.claude/` を参照できるようにする。同時に、tracked 運用 repo（idd-claude 自身 / feedman / altpocket 等）では一切挙動を変えないこと、注入失敗で reset サイクル自体を倒さないこと（fail-open）を最優先の制約とする。self-hosting 上で稼働するため後方互換性と冪等性が要件の中核となる。

## Requirements

### Requirement 1: gitignore 運用 repo への `.claude/` 注入

**Objective:** As a watcher 運用者, I want gitignore 運用 repo の worktree reset 後に REPO_DIR の `.claude/` を worktree へ注入してほしい, so that agent が `.claude/agents` `.claude/rules` を読める健全な状態で起動できる

#### Acceptance Criteria

1. While worktree reset 直後に worktree に `.claude/` が存在しない状態であり, when REPO_DIR にローカル `.claude/` が存在するとき, the watcher shall REPO_DIR のローカル `.claude/` を当該 worktree へ注入する
2. When `.claude/` 注入が成功したとき, the watcher shall agent runtime に必要な構成（少なくとも `.claude/agents` および `.claude/rules`）が worktree から参照可能な状態にする
3. The watcher shall `.claude/` の注入を worktree reset 完了後かつ agent 起動前の時点で実施する
4. When `.claude/` 注入が成功したとき, the watcher shall 注入を行った旨を観測可能なログとして出力する

### Requirement 2: tracked 運用 repo での既存挙動非変更（NO-OP）

**Objective:** As a tracked 運用 repo の運用者, I want `.claude/` を commit している repo の挙動を一切変えないでほしい, so that 既存稼働中の idd-claude 自身・consumer repo が本機能導入によって退行しない

#### Acceptance Criteria

1. While worktree reset 直後に worktree に既に `.claude/` が存在する状態であるとき, the watcher shall その worktree の `.claude/` を REPO_DIR のローカル版で上書きしない
2. If REPO_DIR にローカル `.claude/` が存在しないとき, the watcher shall 注入を行わず何もしない（NO-OP）
3. While 既定設定で稼働しているとき, the watcher shall tracked 運用 repo に対して本機能導入前と外形的に同一の振る舞い（reset → agent 起動）を保つ
4. The watcher shall 注入の有無にかかわらず既定で安全側（既存挙動不変側）に倒れる振る舞いを採る

### Requirement 3: 注入の fail-open（失敗時の継続）

**Objective:** As a watcher 運用者, I want `.claude/` 注入が失敗しても reset サイクル自体を倒さないでほしい, so that 注入の問題が無実の Issue を claude-failed 化させない

#### Acceptance Criteria

1. If `.claude/` 注入が失敗したとき, the watcher shall warn レベルのログを出力する
2. If `.claude/` 注入が失敗したとき, the watcher shall reset → agent 起動のサイクルを中断せず継続する
3. If `.claude/` 注入が失敗したとき, the watcher shall 当該 Issue を注入失敗のみを理由に claude-failed へ遷移させない

### Requirement 4: 注入の安全性・冪等性

**Objective:** As a watcher 運用者, I want 注入が冪等で worktree のファイル属性を壊さないでほしい, so that 繰り返し実行・並列 slot 運用でも一貫した結果が得られ data-loss が起きない

#### Acceptance Criteria

1. When 同一条件で `.claude/` 注入が複数回実行されたとき, the watcher shall 1 回実行した場合と同じ worktree の `.claude/` 状態を生成する
2. The watcher shall 注入対象に worktree の `.claude/` 以外の tracked / untracked ファイルを巻き込まない
3. While worktree が gitignore 運用 repo であるとき, the watcher shall 注入した `.claude/` を worktree の untracked（commit 対象外）状態のまま保つ
4. The watcher shall `.github/scripts/idd-claude-labels.sh` を注入対象に含めない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While 本機能を有効化せず既定で稼働しているとき, the watcher shall 既存の env var 名・ラベル遷移契約・exit code 意味・ログ書式を変更しない
2. The watcher shall worktree reset の既存契約（`git reset --hard origin/<base>` → `git clean -fdx` の順序・data-loss 防止方針、#180 / #198）を退行させない
3. If 後方互換を破る変更が必要になった場合, the watcher shall 既定値を既存挙動側に置き、migration note を伴って導入する

### NFR 2: 冪等性と self-hosting 安全性

1. When watcher が連続サイクルで同一 slot worktree を処理したとき, the watcher shall 注入処理によって前サイクルの注入状態に依存しない一貫した結果を生成する
2. While 並列 slot（PARALLEL_SLOTS > 1）で複数 worktree を処理しているとき, the watcher shall 各 worktree の `.claude/` 注入を互いに干渉させない

### NFR 3: 可観測性

1. The watcher shall 注入の実行・スキップ（NO-OP）・失敗を、運用者がログから判別できる形で記録する

## Out of Scope

- グローバル `~/.claude` フォールバック経路の追加（本 Issue のスコープは REPO_DIR からの注入に限定。グローバルフォールバック不在は degraded の根本原因の 1 つだが本機能では扱わない）
- consumer repo が `.claude/` を gitignore すべきか tracked にすべきかの運用方針自体の決定（repo ごとの運用判断に委ねる）
- `.github/scripts/idd-claude-labels.sh` など agent runtime に不要な足場ファイルの worktree への配布
- 注入元 `.claude/` の内容生成・更新（`install.sh` の責務であり本機能では生成しない）
- 注入手段（auto-detect 方式か新規 env var opt-in 方式か、コピーに用いるコマンドや実装上の関数構成）の確定（design / 実装の領分。要件は観測可能な振る舞いのみを規定する）

## Open Questions

なし
