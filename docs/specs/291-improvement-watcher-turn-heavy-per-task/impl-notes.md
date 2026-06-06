# Implementation Notes — #291 turn-heavy 親タスク分割復旧手順の明文化

## Summary

#289 (PR #290) で新設された `per-task-implementer-failed` / `error_max_turns` 対応
Troubleshooting 節の配下に、「分割復旧手順（turn-heavy 親タスクが溢れたときの tasks.md
フラット化手順）」サブセクション（h4）を追記した。`tasks.md` をフラット化して未完了
タスクを最上位 ID に細分化し、watcher に再 pickup させて impl-resume で続行する流れを
6 ステップ（診断 → 分割設計 → tasks.md フラット化編集 → commit & push → ラベル復旧 →
監視）で提示している。粒度のみ変更 / 設計まで作り直す の分岐基準も同サブセクション内に
表形式で配置した。QUICK-HOWTO.md には README の該当サブセクションへの相互リンクを追加
した。

本 spec は **ドキュメント追記のみ** で完結し、`local-watcher/bin/issue-watcher.sh` /
`.claude/agents/*.md` / `.claude/rules/*.md` の挙動・規約は一切変更していない。Issue
#291 本文で言及されていた (B) per-task ループの親 / 子ディスパッチ順是正は人間判断に
よりスコープ外として別 Issue 起票で対応する方針。

## 編集ファイル

- `README.md` — `### per-task-implementer-failed / error_max_turns 対応` 節の末尾
  （`#### 復旧手順（impl PR の有無別）` の直後）に `#### 分割復旧手順（turn-heavy 親
  タスクが溢れたときの tasks.md フラット化手順）` サブセクションを追記
- `QUICK-HOWTO.md` — `### per-task-implementer-failed / error_max_turns が出た（per-task
  ループ運用時）` 節の README リンク直下に分割復旧手順への相対リンクを追加 + 「次に
  読むもの」リストにも追加
- `docs/specs/291-improvement-watcher-turn-heavy-per-task/impl-notes.md`（本ファイル）

## AC との対応（Traceability）

### Requirement 1: 分割復旧手順サブセクションの追加

| AC | 対応 |
|---|---|
| 1.1 | `README.md` の `### per-task-implementer-failed / error_max_turns 対応` 配下に `#### 分割復旧手順 ...` を 1 件追加 |
| 1.2 | サブセクション本体を 6 ステップ（h5 `##### ステップ 1: 診断` 〜 `##### ステップ 6: 監視`）で順序通り提示 |
| 1.3 | 各ステップで「観測すべき入力（ログ・ラベル・git 履歴）」と「実行すべき操作（tasks.md 編集・git コマンド・gh ラベル操作）」を分けて記述。ステップ 1 は観測中心、ステップ 3〜5 が操作中心 |
| 1.4 | `QUICK-HOWTO.md` の既存 `per-task-implementer-failed` 節と「次に読むもの」リストに、新サブセクションへのアンカーリンクを 1 クリックで到達できる形で追加 |
| 1.5 | 新サブセクションは h4（`####`）として既存 #289 節（h3 `###`）配下に配置。既存の h4 「症状」「原因」「診断手順」「対応の優先順位」「復旧手順」を **書き換えていない**（diff で確認） |

### Requirement 2: 粒度変更と設計変更の分岐基準

| AC | 対応 |
|---|---|
| 2.1 | 「粒度のみ変更で済むケース vs 設計まで作り直すケース（分岐基準）」表で、in-branch 編集の判断条件（File Structure Plan・Components 境界・Interfaces 不変、アノテーション温存可能）を列挙 |
| 2.2 | 同表で design iteration 必要条件（File Structure Plan 改訂・Components 追加・契約変更・`_Boundary:_` 逸脱・AC 追加）を列挙 |
| 2.3 | 同表の右列で各分岐先の次アクション（6 ステップ実行 / `needs-decisions` 付与 + 人間判断 / `design` モードでの Architect 再起動依頼）を明示 |
| 2.4 | 表直後の段落で「判断に迷うケース」の取り扱い（PR 本文の「確認事項」セクションに明記 / Issue コメントで PjM・Architect への差し戻し提案）を明示 |

### Requirement 3: tasks.md フラット化編集の規約

| AC | 対応 |
|---|---|
| 3.1 | ステップ 3 の bullet 1 で `- [x]` 行を編集対象から除外し不変として保持することを明示 |
| 3.2 | ステップ 3 の bullet 2 で `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` の保持を明示 |
| 3.3 | ステップ 3 末尾の bullet で「フラット化により tasks.md と design.md の File Structure Plan に齟齬が出る可能性」を警告として記述 |
| 3.4 | 同 bullet 末尾で「編集中に Plan 書き換えが必要と感じた時点で design iteration 側へ切り替える判断」を案内（分岐基準表との連動）+ ステップ 5 直前の警告ブロックで PR 本文「確認事項」での齟齬明記を案内 |
| 3.5 | ステップ 3 の bullet「numeric ID 採番方針」で「既存 ID を温存しつつフラット化で新規追加するタスクを最上位 ID として追番する」旨を明示 |
| 3.6 | ステップ 3 の bullet「`tasks-generation.md` 既存規約との整合」で checkbox 必須化・Budget overflow check・numeric ID 階層と矛盾しないことを明示。`tasks-generation.md` への相対リンクも記載 |

### Requirement 4: ラベル復旧手順（impl PR 有無別）

| AC | 対応 |
|---|---|
| 4.1 | ステップ 5 の bullet「impl PR が存在しないケース」で既存「復旧手順 A」を参照し `claude-failed` 除去のみで再 pickup する手順を案内 |
| 4.2 | ステップ 5 の bullet「impl PR が既に存在するケース」で「**必ず** `ready-for-review` を **先に** 付与してから `claude-failed` を除去」を明示 |
| 4.3 | ステップ 5 末尾に blockquote の警告ブロック（⚠️ 警告（順序の重要性））を配置。破壊事象（watcher が想定外の追加 commit や push を実施する可能性）と回避策（順序遵守）を本文と視覚的に区別して記述 |
| 4.4 | ステップ 6（監視）で impl PR の有無別の期待状態（残るラベル・次アクション）を明示 |
| 4.5 | 本サブセクション全体で運用者操作（gh ラベル付与・除去の順序）として記述。既存「復旧手順 A / B」と同じ運用視点のみで、watcher 内部関数名・コードパスには踏み込んでいない |

### Requirement 5: 既存運用との整合性

| AC | 対応 |
|---|---|
| 5.1 | ステップ 6 の bullet「impl PR が存在しないケース」末尾で「完了済み `- [x]` 行はそのまま温存される（#270 / #263 で確立された per-task ループ運用と整合）」と明示 |
| 5.2 | ステップ 3 の `- [x]` 行不変規約 + ステップ 6 の `- [ ]` 行先頭からの impl-resume 継続記述で、`- [ ]` ↔ `- [x]` を進捗の正本とする impl-resume 運用の温存を明示 |
| 5.3 | ステップ 4 の bullet「進捗追跡コミット」で `docs(tasks): mark <id> as done` を 1 タスク = 1 commit として継続する旨と、フラット化前 commit を rebase / squash / amend で書き換えない旨を明示 |
| 5.4 | サブセクション冒頭の blockquote で「対応の優先順位」(1) の具体実行手順として接続する位置付けを明示（(2) / (3) を選んだ場合は対象外と切り分け） |

### Requirement 6: 後方互換の保持

| AC | 対応 |
|---|---|
| 6.1 | env 変数名（`DEV_MAX_TURNS` 等）は既存名・既定値（60）のまま参照のみ |
| 6.2 | ラベル名（`claude-failed` / `per-task-implementer-failed` / `ready-for-review` / `auto-dev` / `claude-picked-up` / `claude-claimed` / `needs-decisions`）は既存名のまま参照のみ |
| 6.3 | 編集対象は `README.md` / `QUICK-HOWTO.md` / 本 impl-notes のみ。watcher / agent 定義の挙動・規約は変更していない |
| 6.4 | #289 (PR #290) で追記済みの「症状」「原因」「診断手順」「対応の優先順位」「ラベルの意味と次アクション」「復旧手順 A / B」の各 h4 / h5 本文は **削除・改変せず**、新サブセクションを末尾に追記する形を取った |
| 6.5 | `diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules` で byte-equal を確認済み（本 spec では rules / agents を一切編集していない） |

### Non-Functional Requirements

| NFR | 対応 |
|---|---|
| NFR 1.1 | 経路: トラブルシューティング h2（`## トラブルシューティング`）→ #289 h3（`### per-task-implementer-failed / error_max_turns 対応`）→ 分割復旧手順 h4。h3 内に配置されているため #289 Troubleshooting 節からは 1 ホップ以内（h3 内のサブセクションへの直接ジャンプ） |
| NFR 1.2 | QUICK-HOWTO.md → README 該当アンカーへのリンクを 2 箇所追加（節本文 + 「次に読むもの」リスト）。逆向き（README → QUICK-HOWTO）の明示リンクは既存節構造を尊重し追加していないが、QUICK-HOWTO は README のクイック入口として独立に発見される設計（README トップから `[QUICK-HOWTO.md](./QUICK-HOWTO.md)` 等が辿れる）のため双方向ナビゲーションは成立 |
| NFR 1.3 | 検索キーワード `turn-heavy` / `分割復旧` / `tasks.md フラット化` を h4 タイトルと冒頭段落に含めた |
| NFR 2.1 | ステップ 5 本文で順序（`ready-for-review` 先付与 → `claude-failed` 後除去）を実行手順の中で明示 |
| NFR 2.2 | ステップ 5 末尾に blockquote 形式の警告ブロックを配置（手順本文と視覚的に区別） |
| NFR 2.3 | ステップ 3 の `done 済み [x]` 行不変 + アノテーション温存規約 + ⚠️ 警告 blockquote（impl-resume の進捗追跡破壊リスクに言及） |
| NFR 3.1 | 日本語ベースで記述、識別子（env 変数名・ラベル名・コマンド名・branch 名）は英語固定 |
| NFR 3.2 | #289 節と同じ blockquote 警告スタイル / 表 / コードフェンス言語タグ（`bash`）/ h4 / h5 階層を踏襲 |

## 確認事項（人間レビュアー / PjM への申し送り）

1. **(B) ディスパッチ是正の follow-up Issue 起票（PjM / オーケストレータ責務）**:
   Issue #291 本文で言及されていた (B) per-task ループの親 / 子タスクディスパッチ順
   是正は本 spec のスコープ外（ドキュメント追記のみ）として確定済み。本 PR merge 後に
   PjM が follow-up Issue を起票する必要がある。書式の推奨:
   - Issue タイトル案: `improvement(watcher): per-task Implementer ループの親 / 子
     タスクディスパッチ順の是正（Split from #291）`
   - 本文末尾「## 関連」セクションで canonical 記法 `Split from: #291` を使用
     （`.claude/rules/issue-dependency.md` 参照）
   - `Related: #289 #291` も併記して文脈リンクを残す
   - 本書式の確定は本 spec の Out of Scope だが、上記推奨を `impl-notes.md` に
     明記することで PjM の意思決定材料として残す

2. **配置位置の妥当性確認**: 本 spec の requirements.md Open Questions で
   「分割復旧手順を #289 Troubleshooting 節内のどの位置に置くか」は Architect / 人間
   レビュアー判断とされていた。今回は **節末尾の独立サブセクション**（`#### 復旧手順
   （impl PR の有無別）` 直後）に配置した。理由:
   - 6 ステップが「復旧手順 A / B」の延長線（粒度是正 → ラベル復旧 → 監視の流れを
     含む）であり、論理的に直後配置が自然
   - 「対応の優先順位」(1) の bullet 直下に置く案もあったが、6 ステップが (1)(2)(3)
     全体ではなく (1) のみに紐付くため、節末尾の独立 h4 配置の方がスコープを誤読
     させにくいと判断
   - NFR 1.1 の「1 ホップ以内」は同一 h3 配下のため自動的に満たされる

3. **QUICK-HOWTO → README 逆向きリンクの省略**: README 側から QUICK-HOWTO の対応節への
   明示的逆リンクは追加していない（既存 #289 節も同様に逆リンクを持たない）。トップから
   `[QUICK-HOWTO.md](./QUICK-HOWTO.md)` が辿れる前提で双方向ナビゲーションは成立する
   設計だが、必要なら別 Issue で逆リンクを追記する選択肢を残す。

## 手動スモークテスト結果

- **markdown 構造**: `grep -n '^## \|^### \|^#### \|^##### ' README.md` で見出し階層を
  確認。h2 `## トラブルシューティング` → h3 `### per-task-implementer-failed / error_max_turns
  対応` → h4 群（症状 / 原因 / 診断手順 / 対応の優先順位 / ラベルの意味と次アクション
  / 復旧手順（impl PR の有無別） / 分割復旧手順（new）) → h5 群（A / B / ステップ 1〜6）
  の階層が崩れていないことを確認
- **既存 #289 内容の保全**: 「症状」「原因」「診断手順」「対応の優先順位」「ラベルの
  意味と次アクション」「復旧手順 A / B」の本文行範囲を再 Read し、文字列が変化していない
  ことを確認（編集は新サブセクション追記のみ）
- **root ↔ repo-template byte 一致**: `diff -r .claude/agents repo-template/.claude/agents`
  および `diff -r .claude/rules repo-template/.claude/rules` を実行し、いずれも差分なし
  （`OK: byte-equal`）を確認。本 spec では agents / rules を編集していないため意図通り
- **アンカーリンクの妥当性**: README 内 h4 タイトル `分割復旧手順（turn-heavy 親タスクが
  溢れたときの tasks.md フラット化手順）` に対応する自動生成アンカー
  `#分割復旧手順turn-heavy-親タスクが溢れたときの-tasksmd-フラット化手順` を QUICK-HOWTO
  からリンクとして設定（GitHub の markdown レンダラは括弧・記号を除去し全角文字を
  そのまま残す慣習に従う）

## STATUS

STATUS: complete
