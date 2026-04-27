# Implementation Notes — Phase 1 Reviewer Subagent Gate (#20)

## 概要

設計 PR (#34) で人間レビュー済みの `requirements.md` / `design.md` / `tasks.md` を入力として、
本 Issue の Phase 1 実装を行った。tasks.md の numeric ID 順（1.1 → 1.2 → 2.1 → 2.2 → 2.3 →
2.4 → 2.5 → 3.1 → 3.2 → 4.1 → 4.2）に消化し、各タスクを 1 commit にまとめた。

## 受入基準カバレッジ（requirement ID → 実装場所）

idd-claude には unit test framework が無いため、AC は **コード参照 + 手動スモーク + reviewer.md
契約** の組み合わせで担保する（`.claude/rules/` に従う）。

### Requirement 1: Reviewer サブエージェント定義

| AC | カバー方法 |
|---|---|
| 1.1 | `repo-template/.claude/agents/reviewer.md` を新規追加（commit `aa7d36d`）。`.claude/agents/` も同内容（self-host） |
| 1.2 | フロントマター `name` / `description` / `tools` / `model` の 4 フィールドを既存 developer.md / architect.md と同形式で記述 |
| 1.3 | reviewer.md「役割」「やらないこと（領分違い・絶対禁止）」節で Developer 完了後の独立レビューに限定し、書き換え禁止を明記 |
| 1.4 | reviewer.md「必ず先に読むルール」節で CLAUDE.md / requirements.md / tasks.md / impl-notes.md / design.md の読込順を明示 |
| 1.5 | reviewer.md「出力契約（review-notes.md フォーマット）」節と「RESULT 行の規律」節で `RESULT: approve|reject` 行と Findings 構造を規定 |
| 1.6 | install.sh の既存 `cp -v "$REPO_TEMPLATE_DIR/.claude/agents/"*.md` パスで自動配置されることを smoke test で確認（後述） |

### Requirement 2: impl モードでの Reviewer 起動

| AC | カバー方法 |
|---|---|
| 2.1 | `run_impl_pipeline()`（`issue-watcher.sh:1547`）で Stage A 成功後に `run_reviewer_stage 1` を呼ぶ |
| 2.2 | `run_reviewer_stage()`（`issue-watcher.sh:1443`）が `claude --print` を独立プロセスで起動（`--resume` / `--continue` 不使用）。Stage A / B / C で 3 つの別プロセス |
| 2.3 | `build_reviewer_prompt()`（`issue-watcher.sh:1280` 付近）が `git diff main..HEAD` を inline 展開し、必読ファイルパス（CLAUDE.md / requirements.md / tasks.md / impl-notes.md）を列挙 |
| 2.4 | impl / impl-resume 両方で同じ `run_impl_pipeline` を経由（`issue-watcher.sh:1888-1895`）。skip-triage は MODE=impl 扱いで同じパスを通る |
| 2.5 | `run_impl_pipeline` の Stage A `claude` が非 0 exit → `mark_issue_failed "stageA"` で既存 Developer 失敗時遷移と同等メッセージ |
| 2.6 | `MODE=design` の場合は `run_impl_pipeline` を経由せず、既存パス（DEV_PROMPT 1 セッション）で進む（`issue-watcher.sh:1820-1887`） |
| 2.7 | `mark_issue_failed` 以外で `LABEL_PICKED` を除去せず、Stage C の PjM が `claude-picked-up` → `ready-for-review` への遷移を担当（既存挙動どおり） |

### Requirement 3: Reviewer の判定ロジックと出力契約

| AC | カバー方法 |
|---|---|
| 3.1 | reviewer.md「行動指針」3 項で `requirements.md` の各 numeric ID を 1 つずつチェックすると指示 |
| 3.2 | reviewer.md「判定基準（3 カテゴリのみ）」1 番「AC 未カバー」の定義で観測可能性が無い場合 reject |
| 3.3 | reviewer.md「判定基準」2 番「missing test」の定義で対応テストが見つからない場合 reject |
| 3.4 | reviewer.md「判定基準」3 番「boundary 逸脱」の定義で `_Boundary:_` 違反を reject |
| 3.5 | reviewer.md「判定基準（3 カテゴリのみ）」見出しと「やらないこと」節で 3 カテゴリ以外の reject を明示禁止 |
| 3.6 | reviewer.md「reject しない条件」節でスタイル / 命名 / フォーマット / typo / lint を reject 対象外と明記 |
| 3.7 | reviewer.md「出力契約」の Findings ブロックで `Target` / `Category` / `Required Action` の 3 要素を必須化 |
| 3.8 | reviewer.md「出力契約」の `Verified Requirements` セクションで approve 時に numeric ID 一覧と紐付けを記述 |
| 3.9 | reviewer.md「やらないこと」節で requirements / design / tasks / 実装 / テスト の書き換えを明示禁止 |

### Requirement 4: reject 時の差し戻しループと再 reject の終端処理

| AC | カバー方法 |
|---|---|
| 4.1 | `run_impl_pipeline` の Stage B round=1 reject 分岐で `build_dev_prompt_redo` を組み立て、review-notes.md の Findings を inline 展開して Developer に渡す |
| 4.2 | Stage A' 成功後に `run_reviewer_stage 2` を呼ぶ（`issue-watcher.sh:1597`） |
| 4.3 | round=2 の approve は `;;` で抜けて Stage C に進む（`issue-watcher.sh:1628`） |
| 4.4 | round=2 の reject は `mark_issue_failed "reviewer-reject2"` で claude-picked-up 削除 + claude-failed 付与 + Issue コメント |
| 4.5 | round=2 reject 時の Issue コメントに reject カテゴリ / 対象 ID / `review-notes.md` パス / `$LOG` パスを含める（`issue-watcher.sh:1611-1620`） |
| 4.6 | run_reviewer_stage を bash 関数で 1, 2 のリテラル round 値で 2 回しか呼ばず、Developer 再実行も bash 直線フローで 1 回しか呼ばない（カウンタ変数ではなく状態機械で保証） |
| 4.7 | Stage A' (Developer 再実行) の非 0 exit → `mark_issue_failed "stageA-redo"` で claude-failed 付与（既存 Developer 失敗時遷移と同等） |
| 4.8 | Reviewer round=1 / round=2 の異常終了（claude crash / parse 失敗）は `mark_issue_failed "reviewer-error"` で claude-failed + Issue コメントに `$LOG` パス記載 |

### Requirement 5: 環境変数による上書きと既定値

| AC | カバー方法 |
|---|---|
| 5.1 | Config block: `REVIEWER_MODEL="${REVIEWER_MODEL:-claude-opus-4-7}"` |
| 5.2 | Config block: `REVIEWER_MAX_TURNS="${REVIEWER_MAX_TURNS:-30}"` |
| 5.3 | `run_reviewer_stage` 内 `claude --model "$REVIEWER_MODEL"` |
| 5.4 | `run_reviewer_stage` 内 `claude --max-turns "$REVIEWER_MAX_TURNS"` |
| 5.5 | 既存 env (`TRIAGE_MODEL` / `DEV_MODEL` / `TRIAGE_MAX_TURNS` / `DEV_MAX_TURNS`) を一切参照せず独立に Config 行を追加。新規 env が既存 env に影響を与えるコードパスは無し |

### Requirement 6: 後方互換性とラベル契約の維持

| AC | カバー方法 |
|---|---|
| 6.1 | Config block で既存 env var の名前・既定値・代入順を変更せず、新規 env のみ追加（diff で確認） |
| 6.2 | 既存ラベル定数（`LABEL_PICKED` / `LABEL_FAILED` / `LABEL_READY` 等）を流用、新規ラベル定数を導入していない |
| 6.3 | `LOCK_FILE` / `LOG_DIR` の派生ロジックは無変更。watcher 全体の exit code（0 = 正常 / 1 = 異常）も変更なし。`run_impl_pipeline` の戻り値は呼び出し元のループ内で消費され、watcher のトップレベル exit には影響しない |
| 6.4 | cron / launchd 登録文字列（`REPO=... REPO_DIR=... $HOME/bin/issue-watcher.sh`）は無変更。新規 env の指定は省略可能（既定値あり） |
| 6.5 | Stage C の `build_dev_prompt_c` が project-manager サブエージェントに渡すプロンプトで「title: feat(#N): ...」「PR 本文に受入基準・テスト結果・確認事項」「関連 PR」「ラベル遷移」の指示は既存 DEV_PROMPT と等価 |
| 6.6 | install.sh の `cp -v "$REPO_TEMPLATE_DIR/.claude/agents/"*.md` で reviewer.md が冪等追加されることを scratch repo で 2 回実行 / sha1sum 比較で確認（後述） |

### Requirement 7: ドキュメント更新

| AC | カバー方法 |
|---|---|
| 7.1 | README.md に新セクション「Reviewer Gate (#20 Phase 1)」を追加 |
| 7.2 | 同セクション「環境変数」表に `REVIEWER_MODEL` / `REVIEWER_MAX_TURNS` のデフォルト値と override 例 |
| 7.3 | 同セクション「差し戻しループ」図と「Migration Note」 |
| 7.4 | CLAUDE.md / repo-template/CLAUDE.md の「エージェント連携ルール」節に Reviewer 行を追加 |
| 7.5 | reviewer.md「補足: 対象 repo の CLAUDE.md との整合性」節で「対象 repo の CLAUDE.md のテスト規約が判定基準の正本」と明記 |

### NFR

| NFR | カバー方法 |
|---|---|
| NFR 1.1 | `claude --max-turns "$REVIEWER_MAX_TURNS"` で機械的に上限保証（既定 30） |
| NFR 1.2 | `run_impl_pipeline` で Reviewer は round=1 と round=2 のリテラル呼び出しのみ（最大 2 回） |
| NFR 1.3 | 同じく Developer 再実行は Stage A → Stage A' の 1 回追加のみ（最大 2 回） |
| NFR 2.1 | `rv_log "round=N result=approve|reject|error ..."` を `$LOG` に append（`run_reviewer_stage`） |
| NFR 2.2 | `rv_log "round=N start (model=..., max-turns=...)"` を起動時に出力 |
| NFR 2.3 | `rv_dev_log "redo by reviewer reject (round=N ...)"` を Stage A' 起動前に出力 |
| NFR 3.1 | shellcheck `-S warning` で警告ゼロ通過（後述） |
| NFR 3.2 | dogfooding 正常パス E2E は人間が実機で実施する（本リポジトリの軽微 auto-dev Issue を 1 件流す） |
| NFR 3.3 | reject 経路 E2E も同上（意図的な AC 未カバー実装で 1 ラウンド回す） |

NFR 3.2 / 3.3 は cron / launchd 経由の実機実行が必要なため、本 PR の Test plan に
**人間レビュー時に実施するチェックリスト**として記載する。

## 検証結果

### 静的解析

```
$ shellcheck -S warning local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/idd-claude-labels.sh
（出力なし）
$ echo $?
0
```

→ **新規警告ゼロ**。デフォルト severity `style/info` で実行すると line 840 / 1698 の `SC2012`
（`ls -d` 利用）が出るが、これは本 PR 以前から存在する既存パターンで、本 PR の変更箇所では無い。

### bash syntax

```
$ bash -n local-watcher/bin/issue-watcher.sh
（成功）
```

### cron-like 最小 PATH 依存解決

```
$ env -i HOME=$HOME PATH=/usr/bin:/bin bash -c \
    'export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH" && \
     command -v claude gh jq flock git timeout'
/home/hitoshi/.local/bin/claude
/usr/bin/gh
/usr/bin/jq
/usr/bin/flock
/usr/bin/git
/usr/bin/timeout
```

→ watcher 冒頭の `PATH` 拡張で 6 つの依存全てが解決される（既存挙動どおり、新規依存追加なし）。

### Watcher dry-run（対象 Issue 無し）

```
$ REPO=hitoshiichikawa/idd-claude REPO_DIR=/home/hitoshi/github/idd-claude-watcher \
    TRIAGE_TEMPLATE=local-watcher/bin/triage-prompt.tmpl \
    LOG_DIR=/tmp/watcher-dryrun-logs LOCK_FILE=/tmp/watcher-dryrun.lock \
    LABEL_TRIGGER=__never_match_99999__ \
    bash local-watcher/bin/issue-watcher.sh
...
[2026-04-27 14:42:16] 処理対象の Issue なし
$ echo $?
0
```

→ ラベルクエリにマッチする Issue が無い状態で正常終了。既存の `処理対象の Issue なし` 出力と
exit 0 を維持（要件 6.3 / 6.4 の後方互換性）。

### parse_review_result 単体スモーク（9 ケース）

```
PASS: approve simple
PASS: reject single finding
PASS: reject multi finding
PASS: missing file → exit 2
PASS: no RESULT line → exit 2
PASS: invalid RESULT → exit 2
PASS: multi RESULT → take last (approve)
PASS: Target with japanese paren stripped
PASS: boundary target form
=== Summary: PASS=9, FAIL=0 ===
```

→ 正常系（approve / reject 単一・複数）/ 異常系（file 無 / RESULT 行無 / 不正値）/ 境界
（複数 RESULT の fail-safe / Target 括弧除去 / boundary 形式）すべて PASS。

### prompt builder 単体スモーク（18 ケース）

```
PASS: build_dev_prompt_a(impl) flow label / PR forbid / has PM step
PASS: build_dev_prompt_a(impl-resume) flow label / skips PM
PASS: build_dev_prompt_redo header / embeds Findings / embeds Required Action / handles missing file
PASS: build_reviewer_prompt(1) round / prev=(none) / result format hint
PASS: build_reviewer_prompt(2) round / prev embedded
PASS: build_dev_prompt_c(impl-resume) design PR note / PjM start
PASS: build_dev_prompt_c(impl) 関連 PR: なし
PASS: parse_review_result approve (cross-check)
=== Summary: PASS=18, FAIL=0 ===
```

→ 4 つの prompt builder が AC 2.3 / 4.1 / 6.5 で要求された内容を含むことを確認。

### install.sh 冪等性スモーク（reviewer.md 配置 / AC 6.6）

```
$ rm -rf /tmp/idd-claude-install-smoke && mkdir -p /tmp/idd-claude-install-smoke
$ bash install.sh --repo /tmp/idd-claude-install-smoke
（reviewer.md を含む 6 ファイルが .claude/agents/ にコピーされる）
$ sha1sum /tmp/idd-claude-install-smoke/.claude/agents/*.md > /tmp/sha_1.txt
$ bash install.sh --repo /tmp/idd-claude-install-smoke
$ sha1sum /tmp/idd-claude-install-smoke/.claude/agents/*.md > /tmp/sha_2.txt
$ diff /tmp/sha_1.txt /tmp/sha_2.txt && echo "IDENTICAL"
IDENTICAL
$ diff repo-template/.claude/agents/reviewer.md /tmp/idd-claude-install-smoke/.claude/agents/reviewer.md
（差分なし）
```

→ 2 回実行で全 6 ファイルの sha1sum が一致。reviewer.md 追加以外の破壊的変更なし。

### dogfooding E2E（**人間レビュー時に実施**）

NFR 3.2 / 3.3 / 要件「Out of Scope」の Smoke 4 は cron 実機経由で実施する必要があり、
PR 作成後の人間チェックに委ねる。チェックリストは PR 本文の「Test plan」に転記する:

- [ ] **Smoke 1（正常パス）**: 本リポジトリに軽微 auto-dev Issue を 1 件立て、
      Stage A → B (round=1, approve) → C で PR が `ready-for-review` に到達することを確認。
      PR 内に `review-notes.md` が含まれること
- [ ] **Smoke 2（reject 1 ラウンド）**: 意図的に AC 未カバー実装になる Issue を立て、
      Stage B round=1 で reject → Stage A' → Stage B round=2 のループが動くことを確認
- [ ] **Smoke 3（Reviewer 異常終了）**: `REVIEWER_MAX_TURNS=1` を一時設定して
      Reviewer が RESULT 行を書き終える前に止まる挙動を再現し、
      `claude-failed` 付与 + Issue コメントに `$LOG` パスが含まれることを確認
- [ ] **Smoke 4（design モード非影響）**: `needs_architect: true` 判定される Issue で
      Reviewer が起動せず、既存どおり `awaiting-design-review` 設計 PR が作成されることを確認

## 実装上の判断・解釈

### Reviewer の `tools` フィールド

design.md「Confirmations / Open Risks #1」の提案どおり `Read, Grep, Glob, Bash, Write` を採用。
Bash を許可した理由:

- reviewer.md の判断で `npm test` 等を再実行可能にするため（Open Questions #2 の解決方針と整合）
- `git diff main..HEAD` / `git log` の再取得が必要な場合に Reviewer 自身で取得可能
- ただし reviewer.md「やらないこと」節で `git add` / `git commit` / `git push` / `gh` を明示禁止し、
  副作用は `review-notes.md` の Write 1 ファイルのみに制限

### review-notes.md の commit タイミング

design.md「ブランチ運用方針」と「Confirmations #2」に基づき、Reviewer 自身は commit せず、
Stage C の PjM が PR 作成前に `git add docs/specs/<N>-<slug>/review-notes.md && git commit -m
"docs(review): add reviewer notes for #N"` する方針を採用。`build_dev_prompt_c` プロンプトで
PjM に明示指示。reject 時の Stage A' (Developer 再実行) も、Developer が新しい commit を積む際に
review-notes.md が working tree に残っている → 自然と次の commit に含まれる前提。

### Stage A' redo プロンプトでの Findings 渡し方

`build_dev_prompt_redo` は、`review-notes.md` 全文を triple-backtick markdown ブロックで
inline 展開する方式を採用。プロンプト膨張は懸念だが、Reviewer の Findings は通常数百行未満で、
Developer が「何をどう直すか」を確実に把握できる方が優先と判断。

### 失敗時 Issue コメントの粒度

design.md「Issue コメントの粒度」（Open Questions #1 の解決方針）に従い、`mark_issue_failed`
は **要約 + ログパス + review-notes.md パス** を記載し、reject 理由の逐語転載はしない方針。
詳細は `review-notes.md` 自体（PR に含まれる）を読めば分かる構造。

### shellcheck SC2155 警告対応

`local body="...$(hostname)..."` のように `local` 宣言と同時にコマンド置換すると SC2155
（return value masking）警告が出る。`local hostname_val; hostname_val=$(hostname)` の 2 行に
分離して回避（既存 PR Iteration / Phase A コードでも同パターンが使われている）。

### tasks.md の `_Boundary:_` 「README Documentation」名について

tasks.md task 3.1 / 3.2 で `_Boundary: README Documentation_` とアノテートされているが、
README.md / CLAUDE.md / repo-template/CLAUDE.md の 3 ファイルを触る作業を 1 つの境界名で
表現している。design.md File Structure Plan のディレクトリブロックでは個別ファイル列挙だったが、
tasks.md の boundary 命名は粒度を粗くして「ドキュメント全般」の意味で使われている。
本 PR では README.md と CLAUDE.md 2 ファイルの両方を更新したが、これは tasks 3.1 / 3.2 の
意図どおりと解釈した。

## PR 本文「確認事項」候補（人間レビュー判断に委ねる点）

以下は実装中に気づいた、PR 本文「確認事項」セクションに記載すべき論点:

1. **`build_reviewer_prompt` の git diff サイズ制限**: 大きな PR で `git diff main..HEAD` が
   数万行になると Reviewer プロンプトが Claude の context 上限を圧迫する懸念がある。本 PR では
   diff の行数制限は入れていないが、実運用で問題が出たら `git diff --stat` + 一部ファイルのみ
   inline 展開する設計に切り替える余地がある（Phase 2 以降での tuning 候補として impl-notes に
   記載）。design.md でも明示的なサイズ制限は規定されていないため、現状は無制限のまま採用。

2. **Stage A' redo プロンプトに直前 review-notes.md 全文を inline 展開する選択**: Findings
   セクションのみを切り出す設計も検討したが、Reviewer の Summary や Verified Requirements も
   Developer の理解に役立つため全文を渡している。プロンプト膨張が問題化したら Findings ブロック
   のみ抽出する方式に切り替える余地。

3. **Stage C の PjM プロンプトに review-notes.md を commit させる指示**: design.md「ブランチ
   運用方針」の決定（Reviewer 自身は commit しない）に従ったが、PjM が
   `docs(review): add reviewer notes for #N` を打つことになる。PjM の責務は PR 作成だが
   docs commit を行わせる点は領分のグレーゾーンかもしれない。レビュワー判断で「Reviewer 自身に
   commit させる」案 / 「watcher が commit を打つ」案にリファクタする余地あり。

4. **`parse_review_result` の Target 括弧除去ロジック**: 現状は全角開き括弧 `（` 以降を切り
   捨てる正規表現（`sed -E 's/（.*$//'`）。Reviewer が半角 `(` で書く可能性もあるが、
   reviewer.md のフォーマット例では全角を使っている。半角開き括弧でも同様に処理したい場合は
   `sed -E 's/[（(].*$//'` への変更を検討。

5. **NFR 3.2 / 3.3 の dogfooding E2E**: 本 PR では実機 cron での E2E は実行できていない。
   merge 後に人間が `install.sh --local` を再実行し、本 repo に軽微 auto-dev Issue を立てて
   実機検証する必要がある。Smoke 1〜4 のチェックリストを本ファイルと PR 本文の Test plan に
   記載した。

## design.md / tasks.md との矛盾点

本実装中、design.md / tasks.md と矛盾する重大な事項は発見しなかった。design.md の
「Confirmations / Open Risks」で人間判断に委ねるとされていた 4 点（reviewer の tools フィールド /
review-notes.md commit タイミング / model 既定 / Stage C プロンプトでの言及）はすべて
design.md の提案どおり採用した。それぞれの判断は本ファイルの「実装上の判断」節に記録。

## 派生タスクの候補

Phase 2 以降での検討候補（本 PR スコープ外）:

- Per-task implementation loop (Phase 2): 本 PR は「Developer が全タスク一気に実装 → Reviewer」
  というパターンだが、tasks.md の各 numeric task 単位で TDD 自走ループする運用への切り替え
- Debugger サブエージェント (Phase 3): Reviewer reject 後の Developer 再実行で根本原因解析を
  独立 context で実施する Debugger 役の追加
- Feature Flag Protocol (Phase 4): 実装の段階的有効化（env opt-in 等）を統一規約として整理
- 大規模 diff 時の Reviewer プロンプト圧縮（上記「確認事項」#1 関連）
- review-notes.md の永続化フォーマットを JSON ヘッダ + markdown ボディに分離（後続 Phase
  での監査利便性）

## コミット一覧

本 PR で作成した commit:

1. `aa7d36d` feat(claude): add reviewer subagent definition for impl gate
2. `04e39f6` feat(watcher): add REVIEWER_MODEL / REVIEWER_MAX_TURNS env config
3. `878f099` feat(watcher): add prompt builder functions for impl stage split
4. `c6bed07` feat(watcher): add parse_review_result and run_reviewer_stage
5. `0f86c43` feat(watcher): add run_impl_pipeline state machine for reviewer gate
6. `f849708` feat(watcher): dispatch impl/impl-resume modes via run_impl_pipeline
7. `fbdc9cd` docs(claude): add reviewer agent to inter-agent rules
8. `7956b3b` docs(readme): document Reviewer Gate (#20 Phase 1) and label transitions
9. `(this commit)` docs(specs): add impl-notes for phase 1 reviewer subagent gate
