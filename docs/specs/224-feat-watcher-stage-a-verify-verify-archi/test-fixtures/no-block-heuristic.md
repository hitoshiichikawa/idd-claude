# Implementation Plan

構造化 verify ブロック（センチネル）を持たない spec。ヒューリスティック抽出（第 3 手段）に
倒れる。#160 の散文 + backtick 内コマンド抽出が同一結果を返す回帰確認用。

- [ ] 1. なにかする
  - _Requirements: 1.1_

## Verify(散文形式・センチネル無し)

- lint 緑: `shellcheck local-watcher/bin/issue-watcher.sh` で新規 error なし
