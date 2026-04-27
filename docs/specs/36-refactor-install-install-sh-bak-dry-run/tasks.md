# Implementation Plan

本 tasks.md は `design.md` と対になる実装分割です。各タスクは 1 commit で独立完了可能な粒度とし、
`_Requirements:_` は requirements.md の numeric ID（1.1, 2.3 など）を列挙します。
並列可能タスクには `(P)` と `_Boundary:_` を付けています。

実装順序の方針:
1. ヘルパー関数群を先に追加（既存処理は無変更のため、追加だけで他に影響を与えない）
2. 既存の `setup_repo` / `setup_local_watcher` ブロックをヘルパー呼び出しに置換
3. 引数パース層（`--dry-run` / `--force`）と `-h` ヘルプ更新
4. README 更新と shellcheck / 手動スモークテストで仕上げ

- [ ] 1. ヘルパー関数群の追加（install.sh、副作用なし基盤）
- [ ] 1.1 出力／分類層の関数を追加: `log_action` / `files_equal` / `classify_action` / `ensure_dir`
  - `log_action <NEW|OVERWRITE|SKIP|BACKUP> <path> [<note>]` を実装。`DRY_RUN=true` で `[DRY-RUN]`、
    `false` で `[INSTALL]` の prefix を付け stdout に出力
  - `files_equal <a> <b>` を `cmp -s` で実装（exit 0=同一 / 1=差分 / 2=比較不能）
  - `classify_action <src> <dest>` で `NEW` / `SKIP` / `OVERWRITE` を stdout に返す
  - `ensure_dir <path>` を `mkdir -p` の dry-run 対応版として実装
  - グローバル変数 `DRY_RUN=false` / `FORCE=false` の初期化を `SCRIPT_DIR` 定義の直後に追加
  - 関数定義は引数パースの**後**、`if $INSTALL_REPO` ブロックの**前**に挿入する
  - _Requirements: 3.3, 4.2, 4.3, NFR 2.1_
- [ ] 1.2 ファイル操作層の関数を追加: `copy_template_file` / `copy_glob_to_homebin`
  - `copy_template_file <src> <dest> [--executable]`: 単一ファイル配置。既存があれば
    `classify_action` で SKIP / OVERWRITE 判定、`.bak` は作らない（meta ファイル用）
  - `copy_glob_to_homebin <src_dir> <pattern> <dest> [--executable]`: `shopt -s nullglob` 一時有効化
    後、glob 展開ループで各ファイルを classify → log → cp。マッチ 0 件は `SKIP <pattern> "(no files matched)"`
    を出力して exit 0
  - `--executable` 指定時は配置後に `chmod +x` を 1 ファイルずつ実行（dry-run では note のみ）
  - `shopt -u nullglob` で必ず復元する規律を関数末尾で担保
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6_
- [ ] 1.3 ハイブリッド safe-overwrite 関数を追加: `backup_claude_md_once` / `copy_agents_rules`
  - `backup_claude_md_once <repo_path>`: CLAUDE.md 不在 → noop / `.bak` 不在 → BACKUP / `.bak` 既存 →
    SKIP `(existing .bak preserved)` の 3 分岐を実装（once-only 規律）
  - `copy_agents_rules <src_dir> <dest_dir>`: design.md「Components and Interfaces」の Decision Table
    通り、NEW / SKIP（同一）/ OVERWRITE（差分あり、`.bak` once-only 退避）/ SKIP（既存 .bak +
    `--force` 未指定）/ OVERWRITE+`.bak` once-only（`--force` 指定時）の 5 パスを実装
  - dry-run 時は `cp` を実行せず、log_action のみ出す
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 3.5, NFR 1.1_

- [ ] 2. 引数パース層の改修（`--dry-run` / `--force`）と `-h` ヘルプ更新
- [ ] 2.1 `--dry-run` と `--force` フラグを引数パースに追加し、ヘルプ本文を更新
  - `case $1 in ...` に `--dry-run) DRY_RUN=true; shift ;;` と `--force) FORCE=true; shift ;;` を追加
  - `-h | --help` の出力範囲（現在 `sed -n '3,14p'`）に「オプション:」節を追記し、`--dry-run` と
    `--force` の挙動を 4 行で説明（design.md DR-1, DR-3 参照）
  - 表示範囲の `sed -n` 行範囲をヘルプ追記後の行に合わせて更新する（既存の起動形式表示を壊さない）
  - 対話モードからの `--dry-run` 起動は無効（`if ! $INSTALL_LOCAL && ! $INSTALL_REPO` の判定で
    `--dry-run` のみだと対話モードに入る挙動を維持。ただし `--dry-run --repo` / `--dry-run --local` は
    機能する）
  - _Requirements: 3.6, 4.1, 4.4, 4.6, 5.1_

- [ ] 3. `setup_repo` ブロックの改修（既存個別 `cp` をヘルパー呼び出しに置換）
- [ ] 3.1 CLAUDE.md.bak 保護 + agents / rules ハイブリッド配置への置換
  - 既存 `if [ -f "$REPO_PATH/CLAUDE.md" ]; then ... cp ... .bak; fi` を `backup_claude_md_once "$REPO_PATH"`
    に置換（Req 2.1〜2.5 を一括解決）
  - 既存 `cp -v "$REPO_TEMPLATE_DIR/CLAUDE.md" "$REPO_PATH/CLAUDE.md"` を、`copy_agents_rules` 相当の
    per-file ハイブリッド処理を **CLAUDE.md にも適用**する。具体的には新規ヘルパーをそのまま使うか、
    CLAUDE.md 1 ファイル用に `copy_with_hybrid_overwrite <src> <dest>` を関数化（design.md
    「setup_repo ブロック」セクションの判断に従う）
  - 既存 `cp -v ...*.md` の 2 行を `copy_agents_rules` に置換:
    - `copy_agents_rules "$REPO_TEMPLATE_DIR/.claude/agents" "$REPO_PATH/.claude/agents"`
    - `copy_agents_rules "$REPO_TEMPLATE_DIR/.claude/rules" "$REPO_PATH/.claude/rules"`
  - `mkdir -p` を `ensure_dir` に置換（dry-run 時に作成しないよう徹底）
  - 既存 `cp -v ... feature.yml / issue-to-pr.yml / idd-claude-labels.sh` の 3 行を `copy_template_file`
    に置換（labels.sh は `--executable` 付き）
  - REPO_HINT の heredoc は無変更で維持
  - _Requirements: 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 3.5, 5.4_
  - _Boundary: install.sh (setup_repo block)_
  - _Depends: 1.1, 1.2, 1.3_

- [ ] 4. `setup_local_watcher` ブロックの改修（ワイルドカード化）
- [ ] 4.1 `local-watcher/bin/` 配下の `*.sh` / `*.tmpl` をワイルドカード配置に置換 (P)
  - 既存 3 行（`cp -v issue-watcher.sh` + `cp -v triage-prompt.tmpl` + `if [ -f iteration-prompt.tmpl ]; then cp -v ...`）
    を以下 2 行に置換:
    - `copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.sh"   "$HOME/bin" --executable`
    - `copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.tmpl" "$HOME/bin"`
  - 既存 `chmod +x "$HOME/bin/issue-watcher.sh"` の 1 行は削除（ヘルパー側の `--executable` で全 `*.sh` に
    +x 付与されるため）
  - `mkdir -p "$HOME/bin" "$HOME/.issue-watcher/logs"` は `ensure_dir` を 2 回呼ぶ形に置換
  - macOS 限定 plist コピーは `copy_template_file` に置換
  - LAUNCHD_HINT / CRON_HINT の heredoc は無変更で維持
  - 末尾の前提ツールチェック（`gh`/`jq`/`claude`/`git`/`flock`）は dry-run でも実行（情報提供のみ、
    副作用なし）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 5.4_
  - _Boundary: install.sh (setup_local_watcher block)_
  - _Depends: 1.1, 1.2_

- [ ] 5. `setup.sh` 経由で `--dry-run` が透過することの確認（修正なし想定）
- [ ] 5.1 setup.sh の引数透過を読解で確認し、修正不要であることを記録
  - `setup.sh` の最終行 `exec bash "$IDD_CLAUDE_DIR/install.sh" "$@"` で `"$@"` が全引数を透過する
    ことを確認（design.md DR-4）
  - `bash setup.sh --all --dry-run` を手動実行し、install.sh 側で `[DRY-RUN]` プレフィクスのログが
    出ることをスモークで確認
  - もし透過に問題があれば本タスクで修正、問題なければ「修正不要」を `impl-notes.md` に記録
  - _Requirements: 4.1, 4.2, 4.3_

- [ ] 6. README 更新（冪等性ポリシー節）
- [ ] 6.1 README.md に「冪等性ポリシーと再実行時の挙動」セクションを追加 (P)
  - 配置箇所候補: 「セットアップ」章末尾、もしくは「複数リポジトリ運用」の手前
  - 内容:
    - **CLAUDE.md.bak 保護**: 再実行で初回バックアップが温存されること（過去のバグ修正の Migration Note 含む）
    - **`.claude/agents/` / `.claude/rules/` の上書き挙動**: ハイブリッドポリシー（NEW=配置 /
      同一=SKIP / 差分あり=`.bak` once-only 退避 + 上書き / 既存 `.bak` あれば SKIP / `--force` で強制
      OVERWRITE）の 1 表
    - **`--dry-run` の使い方**: 出力例（`[DRY-RUN] NEW/OVERWRITE/SKIP/BACKUP`）と「`--dry-run` を
      外して再実行すれば dry-run と同じ分類で実適用される」保証の説明
    - **Migration Note**: 既存利用者は再 install のみで自動的に新ガードが適用される旨、`--force` の
      推奨利用シーン
  - 既存「同梱の `install.sh` を使うか…」節の `cp` ベース手動手順との整合を取る（手動手順の冪等性
    対応は別タスクで議論される範囲外、本セクションでは install.sh 経路を推奨と書く）
  - _Requirements: 6.1, 6.2, 6.3, 6.4_
  - _Boundary: README.md_

- [ ] 7. 静的解析と手動スモークテスト
- [ ] 7.1 shellcheck と統合スモークテストを実施し、結果を impl-notes に記録
  - `shellcheck install.sh` 警告ゼロを目指す（既存指摘の継続は OK、新規指摘はゼロを目指す）
  - `bash -n install.sh` で syntax check
  - `/tmp/scratch-repo` 使い捨てディレクトリでの統合スモーク（design.md「Integration Tests」全 6 項目）:
    - 初回 install で全ファイル NEW
    - 再実行で CLAUDE.md.bak 温存 + agents/rules SKIP（identical）
    - agents/developer.md を編集して再実行 → BACKUP + OVERWRITE
    - 再々実行 → SKIP `(existing .bak found)`
    - `--force` で再実行 → OVERWRITE のみ、`.bak` 温存
    - `local-watcher/bin/` に dummy `*.tmpl` を一時追加して `--local --dry-run` 実行 → DRY-RUN NEW
  - dry-run スモーク（design.md「Dry-run Tests」全 4 項目）:
    - `--dry-run` でファイルシステム未変更
    - dry-run 出力と実実行出力が grep diff で一致
    - 実 install 後の `--dry-run` で SKIP のみ
    - `bash setup.sh --all --dry-run` で透過すること
  - dogfood: 本 repo 自身に対し `./install.sh --repo .` 実行して self-hosting 動作確認
  - 結果を `docs/specs/36-refactor-install-install-sh-bak-dry-run/impl-notes.md` に記録
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2, 4.3, 4.4, 4.5, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, NFR 1.1, NFR 1.2, NFR 2.1, NFR 2.2, NFR 3.1_

- [ ]* 8. dogfood E2E（deferrable、本リポジトリへの再 install で観測）
  - 本 repo 自身（idd-claude）に対し、`./install.sh --repo .` を実行
  - CLAUDE.md.bak が初回 install から保護されていること、`.claude/agents/*.md` の SKIP（identical）
    が出ること、追加した `reviewer.md` のような新規ファイルが NEW で配置されることを観測
  - 観測結果を `impl-notes.md` に追記
  - _Requirements: 1.3, 1.5, 2.4, 3.1, 3.2_
