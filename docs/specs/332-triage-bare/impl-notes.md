# 実装ノート — Issue #332 / Triage への --bare オプション導入

## 概要

opt-in env `TRIAGE_BARE`（既定 `false`、`true` 厳密一致）を導入し、有効時に Triage の claude
起動へ `--bare` を付与する。guard hook（`IDD_CLAUDE_HOOKS_ENABLED`）opt-in 時は `--settings`
経由の hook 注入と衝突しうるため、`--bare` を見送り WARN を残す（安全側）。テンプレートの結果
書き込みは Write ツールから **Bash heredoc** に統一し、bare / 非 bare の両モードで同一経路にした。

## 変更ファイル

1. `local-watcher/bin/issue-watcher.sh`
   - config: `TRIAGE_BARE="${TRIAGE_BARE:-false}"`（コメントに自己完結性と衝突回避の根拠）
   - Triage call site: `_triage_bare_args` 配列で条件付与（guard hook 有効時は WARN + 見送り）。
     空配列展開は bash 4.4+ の set -u 安全（guard-hook.sh の既存先例と同一）
2. `local-watcher/bin/triage-prompt.tmpl`
   - 出力指示を「Write ツールを使う」→「Bash heredoc（`cat > {{FILE}} <<'TRIAGE_JSON'`）」へ変更。
     判定ロジック・JSON スキーマ・edit_paths 指示は不変
3. `README.md` — opt-in 機能一覧表に `TRIAGE_BARE` 行（併用不可の注記付き）

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| 1.1〜1.3 | config + `_triage_bare_args` の厳密一致分岐 | grep / 文面確認 |
| 1.4 | 付与は Triage call site のみ（`--bare` の他出現なし） | `grep -n -- --bare issue-watcher.sh` |
| 2.1 | `gh_is_enabled` ガード + WARN ログ | 文面確認 |
| 2.2 | README 行の「併用不可」注記 | 文面確認 |
| 3.1 / 3.2 | テンプレートの出力指示差し替えのみ（diff が当該 bullet のみ） | `git diff` |
| NFR 1 | 追加 env のみ | `git diff` |
| NFR 2 / 3 | shellcheck 新規警告ゼロ / スイート全 PASS | 検証結果 |

## 検証結果

- `shellcheck local-watcher/bin/issue-watcher.sh` → 新規警告ゼロ（既存 SC2329 info 6 件のみ）
- テストスイート → 全 PASS
- `--bare` の実機確認は本環境の CLI 非対話認証が無いため未実施（フラグ存在は `--help` /
  公式 docs で確認済み）。**既定 false の opt-in のため、有効化前に運用環境での Triage
  3 パターン（ready / needs-decisions / needs_architect）スモークを README どおり実施すること**

## 設計上の判断

- **heredoc 統一**: `--bare` のツールセット（公式 docs は Bash / Read / Edit を明記、Write は
  記載なし）に依存しないよう、書き込み経路を Bash に一本化。非 bare でも同一動作のため
  テンプレートの条件分岐が不要
- **guard hook 優先**: `--bare` は hooks をスキップすると明記されており、`--settings` で注入する
  guard hook が無効化される可能性がある。検証不能な組み合わせは安全側（guard 維持）に倒した
- **既定 false**: 判定品質への影響（リポジトリ文脈なしでの needs_architect 判定）は理論上
  小さい（基準はテンプレート内で完結）が、実測なしでの既定変更は行わない（repo の opt-in 文化）

## 確認事項（PR レビュワー向け）

- `edit_paths` の推定品質が bare 化で下がる可能性（リポジトリ構造の事前知識が context に無い。
  ただし Triage は Bash / Read で実ファイルを参照可能なため、テンプレートの指示どおり調査できる）
- 有効化推奨は #325 の `token-usage:` 実測で Triage の固定費を確認してから
