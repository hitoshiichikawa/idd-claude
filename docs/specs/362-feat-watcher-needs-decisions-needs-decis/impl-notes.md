# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `FULL_AUTO_ENABLED` 正規化直後（行 132 直後）に `NEEDS_DECISIONS_MODE` Config block を追加し、cycle startup ログ（行 981）末尾に `needs-decisions-mode=${NEEDS_DECISIONS_MODE}` を追記した。既存 `AUTO_REBASE_MODE` の `case ... esac` パターン（3 値以外を安全側 fallback）を踏襲。
- 重要な判断:
  - 正規化 case の `*)` フォールバックは `all-human` 固定（NFR 1.1 / Req 1.5 安全側）。
  - cycle startup ログは **末尾追記のみ**で既存 grep（`base-branch=` / `full-auto=` 等）を破壊しない（NFR 1.1 / Req 6.4）。
  - 既存 `FULL_AUTO_ENABLED` ブロックの「デフォルト有効化フラグの値正規化」ループに加えず、独立した case 文で正規化する（`FULL_AUTO_ENABLED` の opt-in 制を踏襲）。
  - 配置コメントには Req 1.1〜1.6 / NFR 1.1 / 6.4 への参照を含め、`FULL_AUTO_ENABLED` との AND 二重 opt-in 関係を明示。
- 残存課題: なし（task 2 以降の module 実装 + 配線で本機能の挙動を完成させる）。
- スモーク検証: `bash -n` / `shellcheck` pass。`awk` で Config block を抽出して `env -i` 配下で評価し、7 パターン（unset / 空 / `auto` / `Classified` / `all-human` / `classified` / `all-auto`）について期待通りの正規化結果（不正値はすべて `all-human`、正規値 3 種はそのまま）を確認。
