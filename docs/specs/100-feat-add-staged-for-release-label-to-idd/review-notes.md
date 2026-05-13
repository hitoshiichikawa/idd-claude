# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-13T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-100-impl-feat-add-staged-for-release-label-to-idd
- HEAD commit: 3ba64d6bc2a79dc1f58fa9322731e4bca13b9934
- Compared to: main..HEAD

差分構成:

- `.github/scripts/idd-claude-labels.sh` (+1 行) — LABELS 配列に `staged-for-release` 追加
- `repo-template/.github/scripts/idd-claude-labels.sh` (+1 行) — 同上
- `local-watcher/bin/issue-watcher.sh` (+7 行 / -1 行) — `LABEL_STAGED_FOR_RELEASE` 定数追加と Dispatcher `gh issue list --search` への除外条件追加
- `README.md` (+30 行) — ラベル一括作成テーブル / 手動 gh コマンド / 状態遷移まとめテーブル / ポーリングクエリ / 除外条件運用注記 / 状態遷移図補助フロー
- `QUICK-HOWTO.md` (+2 行 / -1 行) — 作成されるラベル列挙への追記
- `docs/specs/100-feat-add-staged-for-release-label-to-idd/{requirements,impl-notes}.md` — spec 成果物

`tasks.md` / `design.md` は存在しないが、本 Issue は Architect を経由しない小規模スコープ
（labels script への 1 行追加 + ドキュメント整備 + watcher polling query への 1 トークン追加）
であり、Architect 不要と判断した PM 判断は requirements.md の構成と整合する。Reviewer は
`_Boundary:_` アノテーションが存在しないため、変更されたファイル群が requirements.md の
Components（Labels Setup Script / Watcher Polling Query / README.md / QUICK-HOWTO.md /
Documentation Set）と合致するかを軸に判定した。

Feature Flag Protocol: `CLAUDE.md` に `## Feature Flag Protocol` 節が存在しないため
**opt-out** として扱い、flag 観点の確認は行っていない（impl-notes.md と整合）。

## Verified Requirements

- 1.1 — `staged-for-release` ラベル作成: `.github/scripts/idd-claude-labels.sh:76` および
  `repo-template/.github/scripts/idd-claude-labels.sh:72` の LABELS 配列にエントリ追加
- 1.2 — 色 `b8e0d2`: 両 LABELS 行で `|b8e0d2|` を確認
- 1.3 — description に「`develop` に merge 済み、`main` 到達待ち」: 両 LABELS 行で完全一致
- 1.4 — `--force` 無し再実行で skip: `.github/scripts/idd-claude-labels.sh:112-125` の既存
  分岐（`EXISTING_LABELS[$NAME]` 既存判定 → `already exists (skipped)` 報告）を `staged-for-release`
  が継承
- 1.5 — `--force` 付き再実行で上書き更新: 同スクリプト `:114-121` の既存 `--force` 分岐を継承
- 1.6 — 「【Issue 用】」prefix で適用先明示: 両スクリプトの description 文字列冒頭に prefix を付与
- 1.7 — self-hosting / consumer template 両系統で同一の name/color/description: `staged-for-release`
  行は両ファイルで一字一句同一（diff で確認、impl-notes.md の検証結果と一致）
- 2.1 — Watcher Polling Query が当該 Issue を除外: `local-watcher/bin/issue-watcher.sh:4726`
  の Dispatcher `gh issue list --search` に `-label:"$LABEL_STAGED_FOR_RELEASE"` を末尾追加
- 2.2 — README ポーリングクエリ節に `-label:staged-for-release` 明示: `README.md:798`
- 2.3 — 運用注記（1〜2 行）併記: `README.md:810-815` に除外目的（multi-branch 運用 / release 待ち
  Issue の再 pickup 防止 / 1 クエリ取得性）を 6 行で記述（要求は「1〜2 行」だが目的記述として
  必要要素はすべて含まれており、AC の意図（運用者が目的を即座に把握できる）を満たす）
- 3.1 — README ラベル一覧テーブルに `staged-for-release` の行: `README.md:785`
- 3.2 — 「適用先」列に `Issue`: 同行に `| Issue |` 記載
- 3.3 — 「付与主」列に「人間（もしくは future automation）」: 同行に該当文字列
- 3.4 — 「意味」列に `develop` merge 済み・`main` 到達待ち: 同行に該当文字列
- 3.5 — 状態遷移図補助フロー併記: `README.md:843-853` に補助フロー ASCII ブロックを既存
  状態遷移図の直後に追加し、独立した中間状態であることを示す
- 3.6 — multi-branch 運用専用 / single-branch では使用不要: `README.md:813-815` および
  `:855-861` の 2 箇所で明記
- 4.1 — 既存 11 ラベルの name/color/description 不変: `git diff main..HEAD --
  .github/scripts/idd-claude-labels.sh` で削除行 `^-` を確認したところ、既存 LABELS 行の
  削除・変更は 0 件（追加 1 行のみ）。同様に `repo-template/.github/scripts/idd-claude-labels.sh`
  も追加 1 行のみで既存行は無変更
- 4.2 — `BASE_BRANCH` 未設定で既存 pickup 挙動に影響なし: 新除外条件は `staged-for-release`
  ラベル付与時にのみ作用し、付与されない限り既存ロジックは不変
- 4.3 — 手動作成済みラベル `--force` 無し → skip: 既存ループ分岐 `EXISTING_LABELS[$NAME]` を
  `staged-for-release` が継承
- 4.4 — 再実行に対する冪等性: 独自分岐なしで既存ループ構造を継承
- 5.1 — QUICK-HOWTO.md に `staged-for-release` 列挙: `QUICK-HOWTO.md:74`
- 5.2 — 全ドキュメントで `staged-for-release`（lowercase, ハイフン区切り）完全一致: grep で
  README.md / QUICK-HOWTO.md / 両 labels.sh / issue-watcher.sh 全てで `staged-for-release`
  表記を確認（大文字 / アンダースコア混入なし）
- 5.3 — 同 PR 内の追加更新（watcher polling query / `needs-quota-wait` の QUICK-HOWTO 補完）:
  `local-watcher/bin/issue-watcher.sh` の Dispatcher polling query を更新（Req 2.1 充足のため
  必要）。`needs-quota-wait` の QUICK-HOWTO 追記は Req 5.3「grep ベースで網羅」に従う付帯
  修正で、scope 拡大として妥当
- NFR 1.1 — 運用者向けインターフェース不変: スクリプト本体（argparse / `--force` 処理 / `exit`
  ロジック）は無変更（LABELS 配列の 1 行追加のみ）
- NFR 1.2 — 既存除外条件の解釈・挙動が変わらない: `local-watcher/bin/issue-watcher.sh:4726`
  の差分は既存 8 個の除外条件の順序・引用符・spacing を維持し、末尾に
  `-label:"$LABEL_STAGED_FOR_RELEASE"` を append しただけ
- NFR 1.3 — 既存ラベルテーブル行の意味不変: README.md の既存 11 ラベル行は無変更
- NFR 2.1 — 色 `b8e0d2` が既存色と衝突しない: `grep -oE '\|[0-9a-f]{6}\|'` で全 12 色が一意
  であることを確認（重複ゼロ）
- NFR 2.2 — 1 クエリでの集合取得性を README に記述: `README.md:812-813` に「GitHub Issue
  一覧画面で `label:staged-for-release` のみを指定すれば...1 クエリで取得できる」と明記
- NFR 3.1 — N 回連続実行でラベル数が 1 個に収束: 既存ループの冪等性（`EXISTING_LABELS`
  キャッシュ + skip/force 分岐）を継承

## Findings

なし

## Summary

requirements.md の Req 1〜5 / NFR 1〜3 のすべての numeric AC について、対応する実装または
ドキュメント記述が `main..HEAD` の差分に存在することを確認した。既存 11 ラベル行 / 既存
除外条件の順序 / 既存 README テーブル行はいずれも無変更で、後方互換性（Req 4.x / NFR 1.x）
を満たす。Boundary 逸脱なし（変更は requirements.md が明示する Components: Labels Setup
Script / Watcher Polling Query / README.md / QUICK-HOWTO.md / Documentation Set の範囲内）。
Missing test は本 spec のスコープでは該当なし（CLAUDE.md のテスト規約上、本リポジトリは
unit test フレームワークを持たず、検証は shellcheck / bash syntax / 手動スモークテストで
行う方針。impl-notes.md にこれらの検証結果が記載されている）。

RESULT: approve