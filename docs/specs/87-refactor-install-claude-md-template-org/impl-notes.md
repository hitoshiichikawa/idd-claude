# Implementation Notes — #87 refactor(install): CLAUDE.md.org 並置

## 採用方針

**案 2（CLAUDE.md 専用関数 `copy_claude_md_with_org` の新設）** を採用しました。

### 案 1（`copy_with_hybrid_overwrite` にモードフラグ追加）を採らなかった理由

- 既存の `copy_with_hybrid_overwrite` は `.claude/agents/` `.claude/rules/` で使われ、
  Issue #36 の「ハイブリッド safe-overwrite 規律」（`.bak` once-only + `--force` での
  上書き）を実現する責務に集中している。Req NFR 3.1 で本 Issue のスコープは CLAUDE.md
  単一ファイルに限定されており、共有関数にモード分岐を増やすと両系統の責務が交錯する
- CLAUDE.md は Req 2 / Req 6 で `.org` 並置 / merge ガイド表示など固有の挙動が多く、
  独立関数として `copy_claude_md_with_org` に閉じ込めたほうが、bash の可読性とテスト容易性
  （シナリオ別に挙動を独立にトレース可能）が高い
- `--force` 経路では従来挙動（`backup_claude_md_once` + `.bak` 退避 + template 上書き）を
  そのまま再利用したい。新関数は `FORCE=true` 時に `classify_action` ベースの NEW / SKIP /
  OVERWRITE 経路だけ持ち、`.bak` は呼び出し側の `backup_claude_md_once` に委譲する設計とした

### 動作仕様（実装した分岐）

`copy_claude_md_with_org <src> <dest>` の状態遷移:

| dest 状態 | template 差分 | FORCE | 挙動 |
|---|---|---|---|
| 不在 | — | any | `NEW dest`（`.org` 作らず）— Req 1.1 / 1.2 |
| 存在 | 同一 | any | `SKIP dest`（`.org` 作らず）— Req 2.5 |
| 存在 | 差分 | false | `SKIP dest` + `.org` 並置（NEW / SKIP / OVERWRITE） — Req 2.1〜2.4 |
| 存在 | 差分 | true | 既存 OVERWRITE 経路（`.org` 触らず） — Req 3.1, 3.4 |

`.org` 側の冪等経路（FORCE=false / 差分あり）:

- `.org` 不在 → `NEW dest.org`
- `.org` 既存 + 内容同一 → `SKIP dest.org`
- `.org` 既存 + 差分あり → `OVERWRITE dest.org (refresh from template)`

`CLAUDE_MD_ORG_TOUCHED` グローバルフラグを `NEW` / `OVERWRITE` 時のみ true に立て、
配置完了サマリ末尾の merge ガイドメッセージ表示判定に使う（Req 6.1, 6.2）。

`--force` 経路では `backup_claude_md_once` を呼んでから `copy_claude_md_with_org` を呼ぶ。
`backup_claude_md_once` 自体は #36 の once-only 規律をそのまま保持しており（既存 `.bak` を
SKIP）、Req 4.1 / Req 3.3 を満たす。

## 変更ファイル

| ファイル | 内容 |
|---|---|
| `install.sh` | ヘッダの `--force` 説明更新 / 新関数 `copy_claude_md_with_org` 追加 / `setup_repo` 内の CLAUDE.md 配置経路を新関数に切替 / 配置完了サマリ末尾に CLAUDE.md.org merge ガイド追加（条件付き） |
| `README.md` | 「CLAUDE.md.bak の once-only 保護」節を「CLAUDE.md の `.org` 並置 (#87)」に再構成 / dry-run 出力例を新挙動に更新 / `--force --dry-run` 例を追加 / 「CLAUDE.md は別経路」注記を `.org` 並置方式に書き換え / Migration note を 2 段階構成（#87 と #36）に拡張 |
| `docs/specs/87-refactor-install-claude-md-template-org/impl-notes.md` | 本ファイル（新規） |

`backup_claude_md_once` / `copy_with_hybrid_overwrite` / `copy_template_file` /
`copy_agents_rules` / `setup_repo_labels` 等の既存関数は **interface 不変**（NFR 1）。
env var 名・cron 登録文字列・exit code・既存フラグの意味も無変更（NFR 1.1〜1.4）。

## Test Plan（手動スモークテスト結果）

すべて `IDD_CLAUDE_SKIP_LABELS=true ./install.sh ...` で実行（ラベル自動セットアップは
本 Issue 範囲外なので opt-out）。

### シナリオ A: CLAUDE.md 不在 → NEW 配置

- 実行: `./install.sh --repo /tmp/scratch-a`（CLAUDE.md 不在の scratch dir）
- 結果: `[INSTALL] NEW /tmp/scratch-a/CLAUDE.md` のみ。`.org` 不在、`.bak` 不在、merge ガイド非表示
- AC: Req 1.1 / 1.2 / 1.3 ✅

### シナリオ B: 既存 CLAUDE.md（差分あり） → 据え置き + .org 並置

- 実行: 既存 CLAUDE.md（"# My Project Custom..."）配置後 `./install.sh --repo /tmp/scratch-b`
- 結果:
  - `[INSTALL] SKIP /tmp/scratch-b/CLAUDE.md (existing kept, template placed as CLAUDE.md.org)`
  - `[INSTALL] NEW /tmp/scratch-b/CLAUDE.md.org`
  - 既存 CLAUDE.md は **sha256 hash 完全一致**（preserve）
  - `.org` の内容は template と完全一致
  - `.bak` は作成されず
  - merge ガイド `📝 CLAUDE.md.org（最新 template 並置）の merge ガイド:` 表示
- AC: Req 2.1 / 2.2 / 6.1 ✅

### シナリオ C: シナリオ B 状態で再 install（`.org` の冪等性）

- C-1（template 同一の状態で再実行）:
  - `[INSTALL] SKIP /tmp/scratch-b/CLAUDE.md (existing kept, ...)`
  - `[INSTALL] SKIP /tmp/scratch-b/CLAUDE.md.org (identical to template)`
  - merge ガイド非表示（Req 6.1: `.org` を NEW / OVERWRITE していないため）
  - 既存 CLAUDE.md / .org のハッシュ不変
- C-2（`.org` を手動で stale 化 → 再実行）:
  - `[INSTALL] OVERWRITE /tmp/scratch-b/CLAUDE.md.org (refresh from template)`
  - merge ガイド表示
  - 再実行後 `.org` は再び template と完全一致、CLAUDE.md は不変
- AC: Req 2.3 / 2.4 / 5.1 / 6.1 / 6.2 ✅

### シナリオ D: 既存 CLAUDE.md と template 同一 → SKIP

- 実行: template を CLAUDE.md として配置後 `./install.sh --repo /tmp/scratch-d`
- 結果: `[INSTALL] SKIP /tmp/scratch-d/CLAUDE.md (identical to template)` のみ
- `.org` 不在、`.bak` 不在、merge ガイド非表示
- AC: Req 2.5 ✅

### シナリオ E: シナリオ B 状態 + `--force`

- 実行: 既存カスタム CLAUDE.md (`.bak` 不在) で `./install.sh --repo /tmp/scratch-e --force`
- 結果:
  - `[INSTALL] BACKUP /tmp/scratch-e/CLAUDE.md → CLAUDE.md.bak`
  - `[INSTALL] OVERWRITE /tmp/scratch-e/CLAUDE.md (--force)`
  - `.bak` の内容はカスタム CLAUDE.md（"# My Project Custom CLAUDE.md (E)..."）と一致
  - 上書き後の CLAUDE.md は template と一致
  - `.org` 不在、merge ガイド非表示
- AC: Req 3.1 / 3.2 / 3.4 ✅

### シナリオ F: 既存 .bak ありの状態で再 install

- F-1（`--force` なし、既存 `.bak` あり、CLAUDE.md カスタム）:
  - `[INSTALL] SKIP /tmp/scratch-f/CLAUDE.md (existing kept, ...)`
  - `[INSTALL] NEW /tmp/scratch-f/CLAUDE.md.org`
  - 既存 .bak は `a14125c0...` のまま不変（Req 4.1）
  - 既存 CLAUDE.md は据え置き（Req 4.3）
- F-2（`--force` あり、既存 `.bak` あり）:
  - `[INSTALL] SKIP /tmp/scratch-f/CLAUDE.md.bak (existing .bak preserved)`
  - `[INSTALL] OVERWRITE /tmp/scratch-f/CLAUDE.md (--force)`
  - 既存 .bak は once-only 規律で温存（Req 3.3）
  - CLAUDE.md は template で上書き
- AC: Req 3.3 / 4.1 / 4.2 / 4.3 ✅

### 追加検証 1: `--dry-run` の整合性

- シナリオ A の状態で `--dry-run` 実行 → `[DRY-RUN] SKIP CLAUDE.md (existing kept...)` /
  `[DRY-RUN] NEW CLAUDE.md.org` を表示、ファイルシステムは不変
- シナリオ B の状態で `--dry-run --force` 実行 → `[DRY-RUN] SKIP CLAUDE.md.bak (existing .bak preserved)` /
  `[DRY-RUN] OVERWRITE CLAUDE.md (--force)`、FS 不変
- AC: Req 5.2 / 5.3 ✅

### 追加検証 2: 既存 .bak と .org の独立運用

- 既存 CLAUDE.md (custom) + 既存 CLAUDE.md.bak ありの状態で `--force` なし install
- `.bak` は不変、`.org` は新規作成、本体は据え置き → Req 4.3 ✅

### 静的解析

- `shellcheck install.sh` → クリーン（warning ゼロ）

## 受入基準と担保テストの対応表

| Req ID | 内容 | 担保テスト |
|---|---|---|
| 1.1 | 不在時 template を CLAUDE.md として配置 | シナリオ A |
| 1.2 | 不在時 .org を作らない | シナリオ A |
| 1.3 | 不在時 NEW ログを 1 行出力 | シナリオ A |
| 2.1 | 既存 CLAUDE.md (差分) を変更しない | シナリオ B |
| 2.2 | .org 不在時に NEW 配置 | シナリオ B |
| 2.3 | .org 既存 + 同一 → SKIP | シナリオ C-1 |
| 2.4 | .org 既存 + 差分 → 更新 | シナリオ C-2 |
| 2.5 | CLAUDE.md と template 同一 → 何もしない | シナリオ D |
| 2.6 | .org の判定は agents/rules と独立 | シナリオ B/C 全体（agents/rules 配下と独立に動作することを目視） |
| 3.1 | --force 時 既存を template で上書き | シナリオ E |
| 3.2 | --force + .bak 不在 → 退避してから上書き | シナリオ E |
| 3.3 | --force + .bak 既存 → .bak 不変 | シナリオ F-2 |
| 3.4 | --force 時 .org を作成・更新しない | シナリオ E / F-2 |
| 3.5 | --force の意味を変更しない | シナリオ E（従来挙動と同じ BACKUP/OVERWRITE シーケンス） |
| 4.1 | 既存 .bak の中身を変更しない | シナリオ F-1, F-2 |
| 4.2 | .bak を .org に自動マイグレーションしない | シナリオ F-1（.bak はそのまま、.org は template から新規作成） |
| 4.3 | .bak 有無に関わらず .org 並置ロジック適用 | シナリオ F-1 / 追加検証 2 |
| 5.1 | 同一入力で 2 回連続実行しても等価状態 | シナリオ C-1 |
| 5.2 | --dry-run で FS 不変・予定操作を表示 | 追加検証 1 |
| 5.3 | --dry-run の出力分類が実実行と一致 | 追加検証 1（NEW / SKIP / OVERWRITE / BACKUP すべて [DRY-RUN] prefix で対応） |
| 6.1 | .org 新規/更新時に merge ガイド表示 | シナリオ B / C-2 |
| 6.2 | CLAUDE.md 不在で .org を作らなかった場合は merge ガイド非表示 | シナリオ A / D |
| 6.3 | README に `.org` 並置仕様 1 セクション | README.md「CLAUDE.md の `.org` 並置 (#87)」節 |
| 6.4 | README に旧挙動からの移行 note | README.md Migration note 2 段構成 |
| NFR 1.1〜1.4 | 既存 env var / フラグ / sudo 不要 / exit code 不変 | install.sh 引数パース・関数 interface 不変、shellcheck pass |
| NFR 2.1 | 操作種別と対象パスを 1 行ログ出力 | 各シナリオの `[INSTALL]` ログ |
| NFR 2.2 | 既存 agents 配置ログとカラム整合 | `printf '%s %-9s %s %s\n'` のフォーマットを共有 (`log_action`) |
| NFR 3.1 | 範囲外ファイル（agents/rules/workflows/ISSUE_TEMPLATE/scripts）の取り扱い不変 | `setup_repo` の他関数呼び出しに変更なし、シナリオ全体で agents/rules が従来通り NEW |

## 確認事項

なし。要件は明確で、実装上の判断点（`--force` 経路の `.bak` 一段呼び出し、merge ガイド
表示判定の global flag、`.org` の更新時メッセージ）はすべて Req に従って一意に決まった。

ただし、Reviewer に注意してほしい設計判断:

- `CLAUDE_MD_ORG_TOUCHED` をグローバル変数として導入した。Bash 関数間の戻り値伝達は
  exit code か stdout になるが、`copy_claude_md_with_org` は他の `copy_*` 関数同様に
  ログ出力に stdout を使うため、副作用としてのフラグはグローバルで持つほうが直感的と判断。
  単一の `setup_repo` 内でのみ使われ、副作用は配置完了サマリ表示の 1 箇所に閉じる
- README の Migration note を 2 段（#87 と既存の #36）に拡張した。Issue #87 の挙動変更が
  「既存ユーザにとって既定動作の変化」になるため、`--force` で従来挙動を取り戻せる旨を
  明示した。Req 6.4 の趣旨に沿う
