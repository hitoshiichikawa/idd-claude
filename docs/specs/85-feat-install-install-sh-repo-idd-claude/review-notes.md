# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-04-30T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-85-impl-feat-install-install-sh-repo-idd-claude
- HEAD commit: e9fde7a5d16c9071f62b926e370b26fcb0c5a421
- Compared to: main..HEAD
- Feature Flag Protocol 採否: opt-out（CLAUDE.md に節なし → 通常の 3 カテゴリ判定のみ）

差分概要:

- `install.sh`: `--no-labels` 引数 + `IDD_CLAUDE_SKIP_LABELS` env 解釈 + helper 群（`log_label_action` / `print_label_manual_command` / `resolve_repo_slug` / `setup_repo_labels`）追加 + `INSTALL_REPO=true` 経路末尾で `setup_repo_labels "$REPO_PATH"` 呼び出し。help 表示も更新（`sed -n '3,23p'`）
- `README.md`: 「GitHub ラベルの自動セットアップ (#85)」節を追加、既存「ラベル一括作成（推奨）」節に warning blockquote 注記
- `repo-template/.github/scripts/idd-claude-labels.sh`: 未変更（`git diff main..HEAD -- repo-template/.github/scripts/idd-claude-labels.sh` が空。Req 6.3 / 6.4 を満たす）
- spec docs（requirements.md / tasks.md / impl-notes.md）新規

## Verified Requirements

- 1.1 — `install.sh:667` で `INSTALL_REPO=true` 経路の末尾に `setup_repo_labels "$REPO_PATH"`。スモーク 3 / 10 で `🏷  GitHub ラベル自動セットアップ` 出力を確認
- 1.2 — `--all --repo` でも `INSTALL_REPO=true` を立てる引数パース（install.sh:85-89）。スモーク 8 で確認
- 1.3 — call-site が `if $INSTALL_REPO; then ... fi` に閉じており、`INSTALL_LOCAL` 単独経路には呼出なし。スモーク 2 で出力にラベル節が出ないことを確認
- 1.4 — 対話モードも `INSTALL_REPO=true` を立てる既存実装に乗るため同じ if ブロックを通る（構造的保証）
- 1.5 — `setup_repo_labels` が引数 1 個（`repo_path`）で受け、内部で 1 つの slug のみ解決。複数 repo を扱わない
- 2.1〜2.5 — `idd-claude-labels.sh` の挙動委譲。`--force` を渡さないため既存 color / description は保護される（install.sh:566-572 のコメント参照）。スモーク 6 で `created=0 exists=11 updated=0 failed=0` を確認
- 3.1 — `command -v gh` で不在検知 → `log_label_action SKIP "gh CLI not found"` + `print_label_manual_command`（install.sh:489-494）。スモーク 7-1 で確認
- 3.2 — `gh auth status` で未認証検知 → SKIP（install.sh:516-520）。スモーク 7-2 で確認
- 3.3, 3.4 — `bash <labels_script> --repo <slug>` の rc != 0 を `FAIL` ログに集約 + 手動コマンド出力 + `return 0` で fail-soft（install.sh:545-573）。スモーク 3 / 8 で `[INSTALL] FAIL ... rc=1` + install 全体 exit 0 を確認
- 3.5 — `print_label_manual_command` で skip / fail 時に手動コマンドを 1 ブロック提示（install.sh:435-450）
- 3.6 — `bash <repo_path>/.github/scripts/idd-claude-labels.sh${repo:+ --repo $repo}` の完全文字列を出力（install.sh:444-449）
- 4.1 — `--no-labels` で `SKIP_LABELS=true` → `setup_repo_labels` 冒頭で SKIP（install.sh:483-487）。スモーク 4 で確認
- 4.2 — opt-out 専用メッセージ `opt-out (--no-labels / IDD_CLAUDE_SKIP_LABELS)` で認証失敗 SKIP と区別可能
- 4.3 — `SKIP_LABELS` は他フラグと独立した bool で、`--all` / `--dry-run` / `--force` の挙動を変更しない
- 4.4 — `SKIP_LABELS=false` で初期化、env / フラグで明示的に true に変える場合のみ opt-out（install.sh:58）
- 5.1 — 成功時 `[INSTALL] OK [labels] created=N exists=N updated=N failed=N` を 1 行で出力（install.sh:566-568）。スモーク 10 で確認
- 5.2 — skip / fail 時に skip 理由 + `print_label_manual_command` の手動コマンドブロック（install.sh:484-486 / 514-518 等）
- 5.3 — `[INSTALL] STATUS [labels] ...` のプレフィクス書式を `log_label_action` で統一
- 5.4 — `DRY_RUN=true` 時に `log_label_action DRY-RUN "would run: bash ... --repo ..."` で API 呼び出さず予定表示（install.sh:507-510）。スモーク 6 で確認
- 6.1 — `--repo` / `--local` / `--all` / `-h` / `--help` / `--dry-run` / `--force` のパース分岐は無変更（diff は `--no-labels` 追加 1 ケースと help 行範囲 `3,21p`→`3,23p` のみ）
- 6.2 — 対話モード分岐 `if ! $INSTALL_LOCAL && ! $INSTALL_REPO; then ...` は無変更（diff 範囲外）
- 6.3, 6.4 — `repo-template/.github/scripts/idd-claude-labels.sh` の git diff main..HEAD が空（未変更）。`bash <script> --repo <slug>` 形式で既存 interface を呼び出す
- 6.5 — `--force` を渡さない + skip / fail 時も exit 0 のため、再 install で破壊しない。スモーク 11（連続 2 回実行）で確認
- 7.1 — README.md の「GitHub ラベルの自動セットアップ (#85)」節で自動実行を明記
- 7.2 — 同節内で `--no-labels` / `IDD_CLAUDE_SKIP_LABELS=true` の opt-out と推奨ユースケースを記載
- 7.3 — 同節末尾で skip 時の手動 fallback 案内（既存「ラベル一括作成（推奨）」節への参照）を記載
- 7.4 — 既存「ラベル一括作成（推奨）」節冒頭に warning blockquote を追加し、自動実行成功時は手動 step 不要であることを明記
- NFR 1.1 — `setup_repo_labels` は `read` を呼ばず非対話
- NFR 1.2 — sudo を呼ぶ箇所なし
- NFR 2.1 — スモーク 10 で `time` 計測 ≈ 1.2 秒
- NFR 2.2 — gh のタイムアウト + 非ゼロ rc を `FAIL` ログに集約（構造的保証）
- NFR 2.3 — `[INSTALL] (OK|SKIP|DRY-RUN|FAIL) [labels] ...` の grep 可能書式
- NFR 3.1 — install.sh 自体は token を扱わず、gh 出力をそのまま流す（gh 自体が token を mask）
- NFR 3.2 — skip 時は `gh auth login` 案内のみ、追加プロンプトなし

## Findings

なし

## Summary

`install.sh` の `INSTALL_REPO=true` 経路に fail-soft なラベル自動セットアップ helper を追加し、
`--no-labels` / `IDD_CLAUDE_SKIP_LABELS` opt-out、dry-run 透過、手動コマンドブロック出力、
冪等性、既存 `idd-claude-labels.sh` interface 不変（diff で確認）まで全 AC をカバー。
shellcheck もクリーン。本リポジトリは bash + markdown 主体で unit test framework が無いため
（CLAUDE.md「テスト・検証」節）、検証は impl-notes.md の手動スモークテスト 12 ケースに依拠
しており、各 AC への紐付けが明示されている。boundary 逸脱なし。

RESULT: approve
