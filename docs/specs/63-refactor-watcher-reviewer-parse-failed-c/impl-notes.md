# Implementation Notes — Issue #63

## 概要

Issue #52 で発生した「Reviewer subagent が `RESULT: approve` をバッククォート付きで
本文中にインライン記述したため watcher の行頭厳密マッチ parser が抽出失敗 →
`parse-failed` → `claude-failed` で約 21 分の Developer + Reviewer 処理が廃棄」事故の
2 層防御対応:

1. **対策 1**: Reviewer Result Parser を「全文 scan + 装飾許容 + 最後のマッチ採用」に緩和
2. **対策 2**: Reviewer agent definition の RESULT 行規律を「独立行・装飾なし・OK/NG 例示」で強化
3. **対策 3**: README に緩和パーサ契約を追記し、reviewer.md の OK/NG 例にクロスリンク

## 変更ファイル一覧

| ファイル | 変更内容 |
|---|---|
| `local-watcher/bin/issue-watcher.sh` | `extract_review_result_token` 新設、`parse_review_result` を委譲化、`run_reviewer_stage` round=2 prev_result 取得を共通化 |
| `.claude/agents/reviewer.md` | 「RESULT 行の規律」節を強化（OK 例 2 件 / NG 例 5 件 / 自己チェック手順） |
| `repo-template/.claude/agents/reviewer.md` | 上記と同一内容を consumer repo 向けにも適用（template 互換性、Req 3.4） |
| `README.md` | 「Reviewer の出力契約」節に緩和パーサ契約を追記、reviewer.md にクロスリンク |
| `local-watcher/test/parse_review_result_test.sh` | 新規（fixture 駆動の smoke test、19 アサーション） |
| `local-watcher/test/fixtures/parse_review_result/*.txt` | 新規 fixture 11 種 |

## Parse 戦略

### 旧実装

```bash
result_line=$(grep -E '^RESULT: (approve|reject)$' "$path" | tail -1 || true)
```

- 行頭固定 + 行末固定で厳密マッチ
- 装飾（バッククォート / bullet / blockquote）は **すべて拒否**
- Issue #52 のインライン `` `RESULT: approve` `` を取りこぼす

### 新実装

```bash
matches=$(grep -oE 'RESULT:[[:space:]]+(approve|reject)([^[:alnum:]_]|$)' "$path" 2>/dev/null || true)
last=$(printf '%s\n' "$matches" | tail -n 1)
case "$last" in
  *approve*) echo "approve"; return 0 ;;
  *reject*)  echo "reject";  return 0 ;;
esac
```

- 全文 scan（`grep -oE` で全マッチを行ごとに抽出）
- 行頭・行末位置を問わず、前後の装飾を許容
- 後続境界文字 `[^[:alnum:]_]` または行末で「approve」「reject」が独立トークンであることを保証
  （`approved` / `rejection` 等の偽陽性を防ぐ）
- `tail -n 1` で **ファイル順最後のマッチ** を採用（Req 1.3、fail-safe）
- `case` 分岐で末尾の境界文字を切り捨てて `approve` / `reject` の 1 単語を出力
- lowercase 完全一致のみ（Req 1.7、`[Aa]pprove` などは正規表現でマッチしないため自然に拒否）

### パイプライン安全性（`set -euo pipefail` 下）

- `grep` の no-match (rc=1) は `|| true` で吸収（pipefail で sed スクリプトが死なない）
- `tail -n 1` で空入力でも空出力 / rc=0 を返すため case で正しくフォールスルー
- ファイル不存在は `[ -f "$path" ] || return 1` で先行ガード

## テスト fixture 一覧（11 件）

| fixture | 期待挙動 | 紐付く AC |
|---|---|---|
| `tail-approve.txt` | approve | Req 4.4 / NFR 1.3（既存形式） |
| `tail-reject.txt` | reject + Findings 抽出 | Req 4.4 / Req 2.1 |
| `inline-approve-backticks.txt` | approve | Req 1.1 / NFR 1.1（**Issue #52 再現**） |
| `inline-reject-backticks.txt` | reject | Req 1.2 / NFR 1.2 |
| `multi-last-wins-approve.txt` | approve（reject の後 approve） | Req 1.3 |
| `multi-last-wins-reject.txt` | reject（approve の後 reject） | Req 1.3 |
| `no-result.txt` | parse-failed (rc=2) | Req 1.6 / NFR 1.4 |
| `uppercase-no-match.txt` | parse-failed (rc=1) | Req 1.7 |
| `decorated-bullet-approve.txt` | approve | Req 1.1（bullet 装飾） |
| `blockquote-reject.txt` | reject | Req 1.2（blockquote 装飾） |
| `reject-with-findings.txt` | reject + Findings 抽出 | Req 2.1 |

加えて **ファイル不存在ケース** を 2 アサーション（Req 1.5）でカバー。
合計 **19 アサーション、すべて PASS**。

## 実行した検証

### shellcheck（NFR 2.1）

```bash
$ shellcheck local-watcher/bin/issue-watcher.sh local-watcher/test/parse_review_result_test.sh install.sh setup.sh
```

- `local-watcher/bin/issue-watcher.sh`: 既存警告のみ（SC2317×8、SC2012×2）。
  **本 PR で新規警告ゼロ**（pre-change baseline 比、NFR 2.1 充足）
- `local-watcher/test/parse_review_result_test.sh`: 警告ゼロ
- `install.sh` / `setup.sh`: 本 PR 無編集 / 警告ゼロ

### Fixture スモーク

```bash
$ bash local-watcher/test/parse_review_result_test.sh
...
PASS: 19, FAIL: 0
```

cron-like 最小 PATH（`env -i HOME=$HOME PATH=/usr/bin:/bin`）でも 19/19 PASS。

### 既存挙動の影響範囲チェック

`parse_review_result` 呼び出し箇所を grep で確認:

```
local-watcher/bin/issue-watcher.sh:2229: stage_checkpoint_read_review_result が呼び出し（API 不変）
local-watcher/bin/issue-watcher.sh:2898: parsed2=$(parse_review_result ...) （reject 詳細抽出、API 不変）
local-watcher/bin/issue-watcher.sh:2903: parsed=$(parse_review_result "$notes_path") （reviewer stage 内、API 不変）
```

戻り値・stdout TSV フォーマット（`<result>\t<categories>\t<targets>`）は完全に
維持しているため、呼び出し側は無改変で動作する（Req 4.3 NFR 3.x）。

## AC 充足マッピング

### Requirement 1: Reviewer 出力 parser の緩和

| AC | 充足方法 |
|---|---|
| 1.1 (approve・装飾許容) | `extract_review_result_token` の `grep -oE 'RESULT:[[:space:]]+(approve\|reject)([^...]\|$)'` で全文 scan / `inline-approve-backticks.txt` / `decorated-bullet-approve.txt` で検証 |
| 1.2 (reject・装飾許容) | 同上 / `inline-reject-backticks.txt` / `blockquote-reject.txt` で検証 |
| 1.3 (複数マッチ最後採用) | `tail -n 1` で最後のマッチを採用 / `multi-last-wins-approve.txt` / `multi-last-wins-reject.txt` で検証 |
| 1.4 (末尾独立行 backward compat) | 緩和パーサは末尾独立行も同じトークンとして検出 / `tail-approve.txt` / `tail-reject.txt` で検証 |
| 1.5 (ファイル不存在 → parse-failed) | `[ -f "$path" ] || return 1` ガード、`parse_review_result` は rc=2 を維持 / fixture 不存在パスで検証 |
| 1.6 (RESULT 行欠落 → parse-failed) | `[ -n "$matches" ] || return 1` / `no-result.txt` で検証 |
| 1.7 (lowercase のみ) | 正規表現で `(approve\|reject)` lowercase 固定 / `uppercase-no-match.txt` で検証 |

### Requirement 2: Findings 抽出の継続動作

| AC | 充足方法 |
|---|---|
| 2.1 (reject 時 Findings TSV) | `parse_review_result` の Category / Target 抽出ロジックは無変更 / `reject-with-findings.txt` / `tail-reject.txt` で TSV 検証 |
| 2.2 (approve 時 categories/targets 空) | 同上、`if result == reject` ブロック外なので空文字維持 / `tail-approve.txt` / `inline-approve-backticks.txt` で TSV 検証 |

### Requirement 3: Reviewer 出力フォーマット指示の強化

| AC | 充足方法 |
|---|---|
| 3.1 (最終 standalone 行) | `.claude/agents/reviewer.md` および `repo-template/.claude/agents/reviewer.md` の「RESULT 行の規律」節で明文化 |
| 3.2 (装飾なし・末尾プローズなし) | 同節で個別禁止項目（バッククォート / bullet / blockquote / 引用符 / 行末プローズ）として列挙 |
| 3.3 (OK / NG 例示) | OK 例 2 件 + NG 例 5 件（Issue #52 事故パターンを含む）を追加 |
| 3.4 (template 同期) | `.claude/agents/reviewer.md` と `repo-template/.claude/agents/reviewer.md` を `diff` で完全一致確認 |

### Requirement 4: 後方互換性

| AC | 充足方法 |
|---|---|
| 4.1 (新規 env var なし) | コード変更で env var の追加なし（grep で確認） |
| 4.2 (ラベル契約不変) | `mark_issue_failed` 等の呼び出し側は無変更 |
| 4.3 (exit code / log 形式不変) | `parse_review_result` rc=0/2 セマンティクス維持。`rv_log "round=N result=..."` 形式も無変更 |
| 4.4 (既存 review-notes.md 再 parse 同決定) | `tail-approve.txt` / `tail-reject.txt` fixture が既存形式を再現 → 同じ approve / reject を返すことを検証 |

### Requirement 5: ドキュメント整合

| AC | 充足方法 |
|---|---|
| 5.1 (README に緩和契約) | README「Reviewer の出力契約」節に「watcher 側の抽出ロジック（Issue #63 緩和パーサ）」5 項目を追記 |
| 5.2 (canonical 形式は依然推奨) | 同節で「緩和パーサは安全網であり、deviation を許可するものではない」旨を明記 |
| 5.3 (cross-reference) | README から `repo-template/.claude/agents/reviewer.md` の「RESULT 行の規律」節へ相対リンク追加 |

### NFR

| NFR | 充足方法 |
|---|---|
| NFR 1.1 (Issue #52 再現 fixture) | `inline-approve-backticks.txt` で approve 検証（PASS） |
| NFR 1.2 (inline-decorated reject) | `inline-reject-backticks.txt` で reject 検証（PASS） |
| NFR 1.3 (歴史的形式) | `tail-approve.txt` / `tail-reject.txt` で同決定検証（PASS） |
| NFR 1.4 (RESULT 行ゼロ) | `no-result.txt` で parse-failure (rc=2) 検証（PASS） |
| NFR 2.1 (shellcheck baseline 維持) | 本 PR で新規警告ゼロ |
| NFR 3.1 (parse 成功時 log 形式) | `rv_log "round=N result=approve\|reject"` のロガー呼び出しは無変更 |
| NFR 3.2 (parse 失敗時 log 形式) | `rv_log "round=N result=error reason=parse-failed"` のロガー呼び出しは無変更 |

## 確認事項（PR レビュワー判断ポイント）

1. **Open Question 1（自己チェック手順）**: requirements.md Open Questions の論点 1 について、
   本 PR では「Reviewer agent definition の RESULT 行規律節に Write 直前の自己チェック
   手順を追加する」までを実装した（reviewer.md の「自己チェック」サブ節）。これで対策 3 の
   範囲とするか、別途より厳格なチェック機構を追加するかは PM / Architect の判断待ち。

2. **Open Question 4（lowercase only）**: AC 1.7 の指定どおり lowercase 完全一致のみを
   実装。将来 `Approve` / `APPROVE` も許容するなら正規表現を `(approve|reject|Approve|Reject|APPROVE|REJECT)` 等に
   拡張可能だが、本 PR では既存契約踏襲・typo 静かな受容回避のため lowercase 限定を維持。

3. **テスト実行の自動化**: 本 PR の `local-watcher/test/parse_review_result_test.sh` は CI から
   自動実行されない（idd-claude には CI が無く手動 smoke のみ）。GitHub Actions 化や cron 化
   の必要性は将来の Issue で別途検討。現状は contributor が手動で `bash local-watcher/test/parse_review_result_test.sh`
   を実行する運用。

4. **Issue #52 遡及対応**: Open Question 3 のとおり Out of Scope（手動運用）。本 PR では
   過去 `claude-failed` Issue の手動再開手順 runbook 化は行わない。

5. **`extract_review_result_token` の単体露出**: テストから sed で関数定義を切り出す方式を
   採用したため、関数を別ファイル化して `source` する必要は無い。将来テストが膨らんで
   保守コストが上がるようなら `local-watcher/lib/parse-review-result.sh` 等に分離する選択肢あり。

## Feature Flag Protocol 採否

idd-claude 本体の `CLAUDE.md` には `## Feature Flag Protocol` 節が **存在しない** ため、
opt-out 解釈（NFR 1.1 の安全側既定）。本 PR では flag 分岐を導入せず、通常の単一実装パスで
parser を直接更新した。
