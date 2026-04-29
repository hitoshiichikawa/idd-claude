# Implementation Notes — #58 PjM agent design PR auto-close 事故防止

## 変更ファイル一覧と AC 対応

| ファイル | 対応した AC |
|---|---|
| `.claude/agents/project-manager.md` | 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 5.1, 5.2, 5.3, NFR 1.1, NFR 1.2, NFR 1.3, NFR 2.1 |
| `repo-template/.claude/agents/project-manager.md` | 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 5.1, 5.2, 5.3, NFR 1.1, NFR 1.2, NFR 1.3, NFR 2.1 |
| `README.md` | 4.1, 4.2, 4.3, 5.4, NFR 2.1, NFR 2.2 |
| 本ファイル (`impl-notes.md`) | 進捗記録のみ（AC 対応なし） |

詳細な対応根拠は本書「AC カバレッジ」節を参照してください。

## 禁止キーワード列挙（9 語）の決定根拠

GitHub の auto-close 機能で反応するキーワードは公式ドキュメント
([Linking a pull request to an issue](https://docs.github.com/en/issues/tracking-your-work-with-issues/linking-a-pull-request-to-an-issue))
で以下の 9 語が列挙されています:

| 動詞原形 | 三人称単数現在 | 過去分詞 |
|---|---|---|
| `close` | `closes` | `closed` |
| `fix` | `fixes` | `fixed` |
| `resolve` | `resolves` | `resolved` |

要件 1.2 / NFR 1.1 はこの 9 語と「大文字・小文字の組み合わせ」の取りこぼし無し検出を要求している
ため、PjM agent 定義および README で 9 語を明示列挙した。検出は `grep -iE` の `-i`
（case-insensitive）で `Closes` / `closes` / `CLOSES` 等の全バリエーションを 1 つの正規表現で網羅できる。

## self-check の実装方式

### 検出ロジック

PjM agent 定義（`.claude/agents/project-manager.md` の「自己点検: auto-close キーワードの禁止」節）に
**Bash + grep -iE** ベースの実装例を記載した:

```bash
grep -iE '(^|[^A-Za-z])(Clos(e|es|ed)|Fix(|es|ed)|Resolv(e|es|ed))[[:space:]]+#[0-9]+'
```

- `(^|[^A-Za-z])` — キーワードの直前が行頭または英字以外（`-`, `*`, `>`, スペース、句読点等）であることを要求。
  これにより `disclosed #5` の `closed` 部分など単語の途中で偶然マッチするケースを除外する一方、
  `- Closes #55` / `> Fixes #10` 等の Markdown 装飾付きパターンは検出対象に含める（NFR 1.2 充足）
- `Clos(e|es|ed)` — `Close` / `Closes` / `Closed` を 1 group で網羅。`Fix` も `(|es|ed)` で空語尾を許容（`Fix` 単独）
- `[[:space:]]+#[0-9]+` — キーワードと `#<番号>` の間に 1 個以上の空白を要求し、Issue 番号付き参照のみを対象とする
  （`closure` 等の名詞や `closed by` 等の文脈は対象外）
- `grep` は行ベースで全行を走査するため、コードブロック・引用ブロック内に出現したキーワードも検出対象に
  含まれる（NFR 1.3 充足）

### 自動修正

検出時の自動修正は `sed -E` で同パターンを `Refs` に置換する例を併記:

```bash
sed -E 's/(^|[^A-Za-z])(Clos(e|es|ed)|Fix(|es|ed)|Resolv(e|es|ed))([[:space:]]+#[0-9]+)/\1Refs\6/gI'
```

`\1` で前置文字（行頭または非英字）を保持、`\6` で `#<番号>` を保持し、間のキーワード部分のみ `Refs` に置換する。

### 不能時の対応

自動修正でも除去しきれなかった場合（置換後に再 grep がヒットする場合や、文脈的に Refs では意味が通らない場合）、
PjM は設計 PR 作成を中断し、Issue から `claude-picked-up` を外して `claude-failed` を付与する
（既存「失敗時の挙動」節と同じ手順を再利用、Req 3.3 充足）。

## スモークテストの結果

CLAUDE.md「テスト・検証」節の方針に従い、本変更は markdown のみ（bash スクリプト / yaml workflow の
変更なし）のため `shellcheck` / `actionlint` 実行は不要。代わりに以下を実施した:

### 1. 両 PjM ファイル間の禁止 + self-check + テンプレート部の同一性確認

```bash
diff <(sed -n '/^## 設計 PR 本文の遵守事項/,/^## 設計 PR 本文テンプレート$/p' .claude/agents/project-manager.md) \
     <(sed -n '/^## 設計 PR 本文の遵守事項/,/^## 設計 PR 本文テンプレート$/p' repo-template/.claude/agents/project-manager.md)
# 差分なし

diff <(sed -n '/^## 設計 PR 本文テンプレート$/,/^---$/p' .claude/agents/project-manager.md) \
     <(sed -n '/^## 設計 PR 本文テンプレート$/,/^---$/p' repo-template/.claude/agents/project-manager.md)
# 差分なし
```

両ファイルで「設計 PR 本文の遵守事項」「自己点検」「設計 PR 本文テンプレート」が完全に一致していることを確認
（Req 1.5 / 2.5 / NFR 2.1 充足）。

### 2. 設計 PR テンプレート本体に auto-close キーワードが混入していないこと

```bash
grep -n -iE '(^|[^A-Za-z])(Clos(e|es|ed)|Fix(|es|ed)|Resolv(e|es|ed))[[:space:]]+#[0-9]+' \
  .claude/agents/project-manager.md repo-template/.claude/agents/project-manager.md
# ヒット箇所:
# - .claude/agents/project-manager.md:49: 「（例: `- Closes #55`）」(禁止理由解説のための引用例)
# - repo-template/.claude/agents/project-manager.md:67: 同上
```

ヒットしたのは禁止理由解説の inline code 例のみで、設計 PR 本文テンプレート（h2 `## 設計 PR 本文テンプレート` 配下）
には混入していない。これは self-check の grep が誤検出しても本来の規約説明として残すべき記述であり、
意図通りの位置にある（Req 2.3 充足）。

### 3. 後方互換性: 既存セクション見出しと実施手順の保持

```bash
grep -nE '^## ' .claude/agents/project-manager.md
# 概要 / 対応 Issue / 含まれる成果物 / 関連 Issue / PR (NEW) / レビュー観点 /
# 次のステップ / 確認事項 — 既存 6 セクションを保持し、新セクションを 含まれる成果物 と
# レビュー観点 の間に挿入したのみ
```

既存の主要 6 セクション（概要 / 対応 Issue / 含まれる成果物 / レビュー観点 / 次のステップ / 確認事項）は
すべて保持されている（Req 5.1 充足）。「実施事項」の手順順序（push → gh pr create → ラベル更新 →
コメント投稿）も変更なし、ラベル遷移契約（`claude-picked-up` 削除 / `awaiting-design-review` 追加）も
変更なし（Req 5.2 / 5.3 充足）。

### 4. 実装 PR テンプレートの `Closes #<issue-number>` が温存されていること

```bash
grep -n 'Closes #<issue-number>' .claude/agents/project-manager.md repo-template/.claude/agents/project-manager.md
# 両ファイルに 1 件ずつ残存
```

実装 PR は merge 時に Issue を close するのが正規の使い方であり、本対応の対象外（Out of Scope）。
Req 4.3 を README で明示し、PjM 定義側でも「やらないこと」節で「設計 PR 本文に」と限定明記した。

### 5. README 内部リンク / 既存記述との整合性

- L1130-1137 で既に「PjM テンプレートが設計 PR 本文に `Refs #N` を採用しており、`Closes #N` ではない」
  と書かれていたため、追加した節（L1757 周辺の「設計 PR 本文の Issue 参照規約」）と整合する
- 内部リンク（`.claude/agents/project-manager.md` への参照）は相対パスで記載

## AC カバレッジ

各 numeric requirement ID と本変更での充足箇所:

| AC | 充足箇所 |
|---|---|
| 1.1 | PjM 定義「設計 PR 本文の遵守事項」第 1 項目（Refs 形式のみ許容） |
| 1.2 | 同節第 2 項目（9 キーワード列挙） |
| 1.3 | 同節 h2 サブタイトル（「auto-close 事故防止」）および冒頭文 |
| 1.4 | 同節第 5 項目（テンプレート外セクション追加禁止）+ 「やらないこと」節の追記 |
| 1.5 | `.claude/agents/` と `repo-template/.claude/agents/` の両ファイルで節を同一文言で記載（diff 確認済み） |
| 2.1 | 設計 PR 本文テンプレート h2 `## 関連 Issue / PR` を新設 |
| 2.2 | 同節 inline コメント `<!-- 例: Refs #42 ... -->` でサンプル提示 |
| 2.3 | 同節サンプルに `Closes` / `Fixes` / `Resolves` を含めない（grep で確認） |
| 2.4 | 同節 inline コメント `<!-- 関連項目が無い場合は「なし」と記載してください -->` + 本体に `なし` 例示 |
| 2.5 | 両ファイルで同一構造（diff 確認済み） |
| 3.1 | PjM 定義「自己点検: auto-close キーワードの禁止」節で `gh pr create` 前後の検査手順を明記 |
| 3.2 | 同節「検出時の対応」第 1 項目（`Refs #<issue-number>` への自動置換手順） |
| 3.3 | 同節「検出時の対応」第 2 項目（`claude-failed` 付与） + 「失敗時の挙動」節への追加 bullet |
| 3.4 | 同節「検出網羅性」3 項目（9 キーワード + 大小文字 + 装飾 + コードブロック） |
| 4.1 | README フェーズ 1 直後の「設計 PR 本文の Issue 参照規約」サブ節（Refs のみ） |
| 4.2 | 同サブ節 2 段落目（auto-close 事故防止の理由 + PR #56 → Issue #55 の実例） |
| 4.3 | 同サブ節末尾の引用ブロック（実装 PR では `Closes` 許容、design / impl の差を明示） |
| 5.1 | 既存セクション見出し 6 件保持（grep `^## ` で確認） |
| 5.2 | 「実施事項」の 4 ステップ順序を変更せず保持 |
| 5.3 | ラベル遷移文言を変更なし（diff で確認） |
| 5.4 | README 同 PR 内に新セクション追加実施 |
| NFR 1.1 | `grep -iE` の `-i` フラグで全大小文字バリエーション網羅 |
| NFR 1.2 | 正規表現 `(^|[^A-Za-z])` で行頭・装飾前置を許容 |
| NFR 1.3 | `grep` 行ベース走査でコードブロック / 引用ブロック内も検出対象に含める旨を明記 |
| NFR 2.1 | PjM 定義 2 ファイル + README で禁止キーワード一覧を 9 語に統一（grep で確認） |
| NFR 2.2 | README フェーズ 1 直後（設計 PR ゲート節）に同一 PR 内で反映 |

## 確認事項（レビュワー / 後続 Issue 候補）

- 自己点検の正規表現は **PjM agent が実行するシェル想定**で書いている。実行環境が GNU grep / BSD grep
  どちらでも `-iE` は共通だが、`sed -E ... /gI` の case-insensitive 修飾子 `I` は GNU sed 限定。
  macOS の BSD sed で実行する場合は `gsed` 利用または個別ケースを並列パターン化する必要がある可能性がある。
  watcher は基本 Linux 想定 + macOS では `brew install gnu-sed` を README で前提化する案も考慮の余地あり
  → 後続 Issue で検討推奨
- 自動修正後の PR body は意味的にレビュワー向けに不自然になる可能性（例: `- Closes #55` を `- Refs #55`
  に置換すると bullet として残るが、文脈的には「関連」より「親 Issue」を意図していた可能性）。
  自動修正は **fail-safe 寄り**（誤って auto-close するよりは Refs に倒す方が安全）として運用するが、
  PjM は自動修正したことを Issue コメントに簡潔に明記する運用も次の改善案として検討余地あり
- impl PR の `Closes #<issue-number>` は本対応の対象外（Out of Scope）。仮に同様の事故を impl PR で
  避けたい場合（例: epic Issue を 1 PR で close しないケース）は別 Issue で扱う

## 派生タスク候補

- 設計 PR テンプレートに「関連 Issue / PR」を **正規セクション化**したことで、Architect 起動時に
  関連 Issue を自動的に列挙する仕組み（Triage 側で issue body から `#<N>` を抽出して PjM プロンプトに
  注入する等）があると即興セクション追加の誘因がさらに減る可能性 → 後続 Issue 候補
- `idd-claude-labels.sh` 等の他のラベル運用スクリプトには影響なし（変更不要）
- watcher のテンプレート展開・ロード経路には変更なし（PjM agent 定義は Claude Code エージェント側で
  read される markdown のみ）
