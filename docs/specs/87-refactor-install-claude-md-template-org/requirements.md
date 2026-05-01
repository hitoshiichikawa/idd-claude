# Requirements Document

## Introduction

`install.sh` は対象 repo に `repo-template/CLAUDE.md` を配置する際、既存 `CLAUDE.md` があると
`CLAUDE.md.bak` に退避してから template で上書きする「上書き優先」挙動を採っている。しかし
`CLAUDE.md` は技術スタック・規約・プロジェクト固有メタなど、利用者が手で書き込んだ重要な
プロジェクト憲章であり、再 install のたびに本体が template に置き換わる UX は破壊的である。

本要件は、`CLAUDE.md` に限り「ユーザーの記述が主、template は参考」という関係に反転する。
既存 `CLAUDE.md` は active のまま据え置き、template 由来のコンテンツは同ディレクトリの
`CLAUDE.md.org` として並置することで、利用者がいつでも最新 template と差分比較・手動 merge
できるようにする。後方互換性のため、従来の上書き挙動は `--force` で escape hatch として残す。

スコープは `CLAUDE.md` の単一ファイル取り扱いに限定する。`.claude/agents/` `.claude/rules/`
`.github/workflows/` `.github/ISSUE_TEMPLATE/` の取り扱いは本 Issue では変更しない。

## Requirements

### Requirement 1: CLAUDE.md の不在時配置

**Objective:** As an idd-claude を初めて install するユーザー, I want template の CLAUDE.md が
そのまま配置されること, so that 初回セットアップではプロジェクトガイドの雛形を即座に得られる

#### Acceptance Criteria

1. When 対象 repo に `CLAUDE.md` が存在せず install.sh が実行される, the install Script shall
   `repo-template/CLAUDE.md` を `CLAUDE.md` として配置する
2. When 上記 1 の配置が行われる, the install Script shall `CLAUDE.md.org` を作成しない
3. When 上記 1 の配置が行われる, the install Script shall 当該配置を `NEW` 種別のログとして 1 行出力する

### Requirement 2: 既存 CLAUDE.md の据え置きと .org 並置

**Objective:** As 既存の CLAUDE.md を編集済みのユーザー, I want 自分の CLAUDE.md が install で
上書きされず、最新 template だけ参照可能な形で並置されること, so that 安全に再 install
できつつ template の差分も確認できる

#### Acceptance Criteria

1. When 対象 repo に既存 `CLAUDE.md` が存在し、かつ template と内容が異なり、`--force` が
   指定されていない状態で install.sh が実行される, the install Script shall 既存 `CLAUDE.md`
   を変更しない
2. When 上記 1 の条件が成立し、`CLAUDE.md.org` が存在しない, the install Script shall
   `repo-template/CLAUDE.md` を `CLAUDE.md.org` として配置する
3. When 上記 1 の条件が成立し、既存 `CLAUDE.md.org` の内容が template と同一である, the install
   Script shall `CLAUDE.md.org` を変更せず、SKIP 種別のログを 1 行出力する
4. When 上記 1 の条件が成立し、既存 `CLAUDE.md.org` の内容が template と異なる, the install
   Script shall `CLAUDE.md.org` を template の最新内容で更新する
5. When 既存 `CLAUDE.md` と template の内容が完全に一致する, the install Script shall
   `CLAUDE.md` を変更せず、`CLAUDE.md.org` を作成しない
6. The install Script shall `CLAUDE.md.org` の作成・更新・スキップを `.claude/agents/` /
   `.claude/rules/` 配下のファイル配置と独立に判定する

### Requirement 3: --force 指定時の従来挙動

**Objective:** As 最新 template を強制適用したい運用者, I want `--force` で従来通り template
で上書きできる escape hatch があること, so that 後方互換性が保たれ、強制更新が必要な場面に
対応できる

#### Acceptance Criteria

1. When 対象 repo に既存 `CLAUDE.md` が存在し、かつ template と内容が異なり、`--force` が
   指定された状態で install.sh が実行される, the install Script shall 既存 `CLAUDE.md` を
   template の内容で上書きする
2. While `--force` 指定の上書きが発生する場合、対象 repo に `CLAUDE.md.bak` が存在しない,
   the install Script shall 上書き直前の `CLAUDE.md` を `CLAUDE.md.bak` として退避してから
   上書きする
3. While `--force` 指定の上書きが発生する場合、対象 repo に既に `CLAUDE.md.bak` が存在する,
   the install Script shall 既存 `CLAUDE.md.bak` を再退避せず温存したまま `CLAUDE.md` を上書きする
4. When `--force` 指定により `CLAUDE.md` の上書きが行われた, the install Script shall
   `CLAUDE.md.org` を作成・更新しない
5. The install Script shall `--force` の意味（差分ありファイルへの強制上書き）を本要件以外で
   変更しない

### Requirement 4: 既存 .bak ファイルの保護

**Objective:** As 過去 install で `.bak` を取得済みのユーザー, I want 過去の `.bak` が今回の
install で消えたり中身が変わったりしないこと, so that オリジナルの編集履歴を失わない

#### Acceptance Criteria

1. While 対象 repo に既存 `CLAUDE.md.bak` が存在する, the install Script shall 既存
   `CLAUDE.md.bak` の中身を変更しない
2. While 対象 repo に既存 `CLAUDE.md.bak` が存在する, the install Script shall 既存
   `CLAUDE.md.bak` を `CLAUDE.md.org` に自動マイグレーションしない
3. The install Script shall 既存 `CLAUDE.md.bak` の有無に関係なく、Requirement 2 の
   `CLAUDE.md.org` 並置ロジックを適用する

### Requirement 5: 冪等性

**Objective:** As 定期的に install.sh を再実行する運用者, I want 何度実行しても予測可能で
破壊的でない動作であること, so that update を恐れずに最新 template を取り込める

#### Acceptance Criteria

1. When install.sh が同一の入力（同じ対象 repo・同じ template バージョン・同じフラグ）で
   2 回連続実行される, the install Script shall 2 回目で `CLAUDE.md` および `CLAUDE.md.org`
   の内容を 1 回目終了時点と等価な状態に保つ
2. When install.sh が `--dry-run` で実行される, the install Script shall ファイルシステムを
   変更せず、`CLAUDE.md` および `CLAUDE.md.org` に対する予定操作を `[DRY-RUN]` プレフィクス付き
   ログとして表示する
3. The install Script shall `--dry-run` での出力分類（NEW / SKIP / OVERWRITE / BACKUP 等）を
   実実行時の分類と一致させる

### Requirement 6: ユーザー向け merge ガイダンス

**Objective:** As 並置された `CLAUDE.md.org` を初めて見るユーザー, I want 何のファイルか・
どう使うかが install 完了直後にわかること, so that template との差分マージ作業に着手できる

#### Acceptance Criteria

1. When install.sh の対象 repo 配置ブロックが `CLAUDE.md.org` を新規作成または更新した,
   the install Script shall 配置完了サマリの末尾に `CLAUDE.md.org` の意味と
   `diff CLAUDE.md CLAUDE.md.org` 等の merge 手順を案内するメッセージを 1 ブロック表示する
2. Where 対象 repo に `CLAUDE.md` が存在しなかったために `CLAUDE.md.org` が作られなかった
   ケース, the install Script shall 上記 1 の merge ガイドメッセージを表示しない
3. The README shall `CLAUDE.md.org` 並置仕様（不在時 NEW / 既存据え置き / `.org` 更新 / 同一時
   SKIP / `--force` での従来挙動）と利用者向け merge 手順を 1 セクションで説明する
4. The README shall 旧挙動（`.bak` 退避＋ template 上書き）から新挙動への移行 note を提示する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The install Script shall 既存環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`,
   `IDD_CLAUDE_SKIP_LABELS` 等）の解釈を変更しない
2. The install Script shall 既存フラグ（`--repo`, `--local`, `--all`, `--dry-run`, `--force`,
   `--no-labels`）の意味を本 Issue 範囲外で変更しない
3. The install Script shall sudo 不要のユーザースコープ install 前提を維持する
4. The install Script shall exit code の意味（0=成功 / 非 0=失敗）を変更しない

### NFR 2: 観測可能性

1. When `CLAUDE.md` または `CLAUDE.md.org` に対する操作が行われる, the install Script shall
   操作種別（NEW / SKIP / OVERWRITE / BACKUP）と対象パスを 1 行ログとして標準出力に書き出す
2. The install Script shall ログ行のフォーマットを既存の `.claude/agents/` 配置ログと
   視覚的に整合させる（同一カラム整列・同一プレフィクス規約）

### NFR 3: 範囲限定の安全性

1. The install Script shall 本要件で規定しないファイル（`.claude/agents/**`,
   `.claude/rules/**`, `.github/workflows/**`, `.github/ISSUE_TEMPLATE/**`,
   `.github/scripts/**`）の取り扱いを変更しない

## Out of Scope

- `.claude/agents/` `.claude/rules/` `.github/workflows/` `.github/ISSUE_TEMPLATE/`
  `.github/scripts/` 配下のファイルへの `.org` 並置方式の適用（将来検討）
- 自動 merge / 自動 diff 表示（`diff` や `git merge-file` の自動実行）
- install 完了後の `git add` / `git commit` / `git push` の自動化
- 既存 `CLAUDE.md.bak` の `CLAUDE.md.org` への自動マイグレーション
- `CLAUDE.md.org` 拡張子と emacs org-mode の衝突回避機構
- `CLAUDE.md.org` を git で追跡するか・無視するか（`.gitignore` への追記等）の方針決定
- ユーザーの `CLAUDE.md` を解析して衝突箇所をハイライトする機能
- `--force` 以外の新規フラグ追加（例: `--no-org`, `--org-only` 等）

## Open Questions

- なし（Issue 本文で判断委ね事項として挙がった 3 点はすべて要件側で確定済み:
  拡張子は `.org` で固定 / `.bak` の自動マイグレーションはしない / agents・rules への
  同種改修は本 Issue スコープ外）
