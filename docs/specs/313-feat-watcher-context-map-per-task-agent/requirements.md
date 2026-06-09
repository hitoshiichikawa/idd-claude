# Requirements Document

## Introduction

idd-claude の per-task Implementer ループ（`PER_TASK_LOOP_ENABLED=true`）では、tasks.md の
1 タスクごとに Developer / per-task Reviewer / Debugger が fresh な Claude session で起動され、
各 session は repo 内の当たり付けをゼロから繰り返す。`.claude/agents/developer.md` は変更前の
広域 grep / glob を必須化しているため、task 件数が増えるほど同一探索が反復され token 消費が
膨らむ。本機能は watcher 側で `_Boundary:_` / design.md の File Structure Plan / 関連 spec を
素材に短い構造化 context metadata（`context-map.md`）を決定論的に生成し、後段 prompt に注入
することで、品質を落とさずに広域探索を抑止することを目的とする。挙動変更は新規 env flag
`CONTEXT_MAP_ENABLED` による opt-in とし、未設定では既存挙動と差分等価を保つ。

## Requirements

### Requirement 1: opt-in 制御 flag による有効化

**Objective:** As an idd-claude 運用者, I want context map 機能を env flag で opt-in 制御できる, so that 既存運用への影響なく新機能を試験導入できる

#### Acceptance Criteria

1. Where `CONTEXT_MAP_ENABLED` is set to `true`, the watcher shall context map 生成と prompt 注入を有効化する
2. If `CONTEXT_MAP_ENABLED` が未設定 or `true` 以外（空文字 / `false` / 任意の値）, the watcher shall context map 生成と prompt 注入を行わず、本機能導入前と差分等価の挙動で動作する
3. The watcher shall `CONTEXT_MAP_ENABLED` の解釈において `true`（lowercase）のみを有効値として扱い、`True` / `1` / `yes` 等は無効として扱う
4. The watcher shall `CONTEXT_MAP_ENABLED=true` であっても `PER_TASK_LOOP_ENABLED=true` でない実行では context map 生成・注入を行わない

### Requirement 2: context-map.md の決定論的生成

**Objective:** As an idd-claude 運用者, I want watcher が短い構造化 context metadata を決定論的に生成する, so that 後段 agent が広域探索の代わりに参照できる

#### Acceptance Criteria

1. When per-task Implementer ループが impl / impl-resume mode で task 実行を開始する前 and `CONTEXT_MAP_ENABLED=true`, the watcher shall `docs/specs/<番号>-<slug>/context-map.md` を生成または更新する
2. The context-map.md shall 対象 task の numeric ID と task 名を記録する
3. The context-map.md shall 対象 task の `_Boundary:_` で宣言されたコンポーネント名を記録する
4. The context-map.md shall `_Boundary:_` コンポーネントから design.md の File Structure Plan を引いて解決された候補ファイルパス一覧を記録する
5. The context-map.md shall 候補テストファイルパス一覧を記録する
6. The context-map.md shall 候補 docs ファイルパス一覧を記録する
7. The context-map.md shall 探索制約（参照すべき範囲・参照すべきでない範囲）を短く記録する
8. The watcher shall context-map.md の生成において前段 agent の内部思考（reasoning / chain-of-thought）を含めない
9. If 対象 task の `_Boundary:_` から候補ファイルが解決できない, the watcher shall context-map.md にその旨を明示し、生成自体は完了させる（生成失敗で per-task ループを停止させない）
10. The watcher shall context-map.md を repo-wide index 規模に肥大化させない（出力サイズの上限を設けて超過時は要約する）

### Requirement 3: 後段 prompt への context map 注入

**Objective:** As a Developer / per-task Reviewer agent, I want context map の内容またはパスが prompt に注入される, so that 広域探索より先に context map を参照できる

#### Acceptance Criteria

1. When `CONTEXT_MAP_ENABLED=true` and context-map.md が生成済み, the watcher shall per-task Developer の起動 prompt に context map の内容またはパスを含める
2. When `CONTEXT_MAP_ENABLED=true` and context-map.md が生成済み, the watcher shall per-task Reviewer の起動 prompt に context map の内容またはパスを含める
3. The Developer agent prompt shall context map を「広域 grep / glob を行う前にまず参照する一次情報」として指示する
4. The Reviewer agent prompt shall context map を「diff range 評価時の探索起点」として指示する
5. If `CONTEXT_MAP_ENABLED` が未設定 or `false`, the watcher shall per-task Developer / Reviewer prompt に context map 関連の追記を行わない

### Requirement 4: agent 定義の両系統反映

**Objective:** As an idd-claude メンテナ, I want `.claude/agents/*.md` の変更が root と `repo-template/` の両系統に byte 一致で反映される, so that consumer repo にも同じ規約が配布される

#### Acceptance Criteria

1. When `.claude/agents/developer.md` を変更する場合, the 実装 shall root（`.claude/agents/developer.md`）と `repo-template/.claude/agents/developer.md` を byte 一致で更新する
2. When `.claude/agents/reviewer.md` を変更する場合, the 実装 shall root と `repo-template/.claude/agents/reviewer.md` を byte 一致で更新する
3. The 実装 shall `diff -r .claude/agents repo-template/.claude/agents` が空である状態を維持する

### Requirement 5: ドキュメント更新

**Objective:** As an idd-claude 運用者, I want 新機能の env var / 目的 / 運用上の注意が README に明示される, so that opt-in 判断と運用に必要な情報を得られる

#### Acceptance Criteria

1. The README shall `CONTEXT_MAP_ENABLED` env var の意味と既定値（未設定＝無効）を記載する
2. The README shall context map 機能が `PER_TASK_LOOP_ENABLED=true` 環境でのみ動作する旨を記載する
3. The README shall context-map.md の生成パス（`docs/specs/<番号>-<slug>/context-map.md`）と生成タイミングを記載する
4. The README shall 本機能のスコープ外（reasoning effort 変更・並列度変更・LLM scout・repo-wide index）を明示する

### Requirement 6: 検証可能性

**Objective:** As an idd-claude メンテナ, I want bash テストで flag on/off の挙動を検証できる, so that 後方互換性と新機能の両方を回帰確認できる

#### Acceptance Criteria

1. The リポジトリ shall `CONTEXT_MAP_ENABLED=true` 時に context-map.md が生成されることを bash テストで検証する fixture / スモークスクリプトを提供する
2. The リポジトリ shall `CONTEXT_MAP_ENABLED=true` 時に per-task Developer / Reviewer prompt に context map が注入されることを bash テストで検証する
3. The リポジトリ shall `CONTEXT_MAP_ENABLED` 未設定時に context-map.md が生成されず prompt 注入も行われないことを bash テストで検証する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The watcher shall `CONTEXT_MAP_ENABLED` 未設定または `true` 以外の値の場合、既存 prompt 内容・既存 stage 遷移・既存 exit code・既存ログ出力を本機能導入前と差分等価に保つ
2. The 実装 shall 既存 env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `PER_TASK_LOOP_ENABLED`, `DEBUGGER_ENABLED` 等）を変更しない
3. The 実装 shall 既存ラベル名を変更しない
4. The 実装 shall 既存 cron 登録文字列（watcher コマンドライン）を変更しない

### NFR 2: 冪等性・安全性

1. The watcher shall context-map.md を再生成する際に冪等であり、同一 input から同一 output を生成する
2. The watcher shall root 権限を要求する処理を追加しない
3. If context-map.md 生成中にエラーが発生, the watcher shall per-task ループ全体を停止させず、エラーログを残して context map なしで従来挙動に fallback する

### NFR 3: スクリプト品質

1. The 変更後の `local-watcher/bin/issue-watcher.sh` および追加モジュールは `shellcheck` 警告ゼロで通過する
2. The 変更後の bash スクリプトは `set -euo pipefail` を冒頭で宣言する

### NFR 4: サイズ制約

1. The context-map.md shall 1 ファイルあたり妥当な上限内に収まる（巨大 repo 索引化を避ける）。具体閾値は design.md で確定する

## Out of Scope

- reasoning effort / model default の変更
- per-task ループの並列度 default 変更
- LLM scout agent の新規起動（決定論的生成のみで試す）
- 完全な repo-wide index の導入
- 既存 agent prompt の単一実装パス（`PER_TASK_LOOP_ENABLED=true` 以外）への context map 注入
- CLAUDE.md / README 以外の consumer 固有ドキュメントの自動配布
- 過去 spec の context-map.md retrofit 生成

## Open Questions

- 生成タイミングと粒度: context map を **per-task ごとに再生成** するか、**Issue 単位で 1 度生成して task 行のみ差し替える** か。前者は task 局所性が高く token 効率が良い一方で生成回数が増える。後者は生成コストが低いが task 固有情報の鮮度が下がる。design フェーズで判定する
- context-map.md の出力サイズ上限（NFR 4.1 の具体閾値）: 行数 / 文字数 / ファイル一覧件数の上限値は design フェーズで確定する
- 候補ファイル解決時に design.md の File Structure Plan が「TBD」やプレースホルダのみで具体パスを持たない spec をどう扱うか（生成スキップ / 警告付き生成 / fallback ヒューリスティック）。design フェーズで判定する
- Debugger agent prompt への context map 注入の要否（Issue 本文の「期待する挙動・ゴール」では Developer / per-task Reviewer のみ明記されている。Debugger は判断委譲点として残す）

## 関連

- Related: idd-codex#34
