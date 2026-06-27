<!-- Issue: #421 -->
<!-- URL: https://github.com/hitoshiichikawa/idd-claude/issues/421 -->

# Implementation Notes

## 設計判断（matcher 緩和 vs 正規化の選択理由）

**採用方針: matcher 緩和（regex / glob ベース）**

理由:

1. **2 経路ある照合点の整合性**: `pt_resolve_diff_range` は (a) 単記パスで bash 文字列等価
   `[ "$subject" = "..." ]` と (b) 連記パスで `sed -nE` の正規表現抽出を併用している。
   subject 正規化（suffix を事前 strip して比較する案）は両経路に「正規化ステップ」を挟む
   必要があり、結果として 2 段階処理になる。一方 matcher 緩和は (a) を「正規 + canonical
   suffix 付き」2 候補のいずれかにマッチで OK、(b) を `( \(#[0-9]+\))?` optional group を
   追加する 1 行修正で済み、変更箇所が局所化される。
2. **拒否境界の表現力**: Req 4 で「空白なし / 括弧なし / 追加文字列 / 非数字」を拒否する
   必要があるが、これは canonical suffix の構造（` (#<digits>)` 行終端）を厳密に正規表現
   側で表現するのが直接的。subject 正規化は「strip すべき接尾辞か否か」を別途判定する
   ステップが必要になり、結果的に同じ判定ロジックを書く羽目になる。
3. **既存ログ列の温存**: NFR 1.1 で「既存 `via=multi-id-marker` の文字列形式と発火条件を
   変更しない」要件があるため、suffix 経路を新タグ（`-with-suffix`）として分離する必要が
   ある。matcher 緩和では via 変数の代入を 4 ケース（`single-id-marker` / `single-id-marker-with-suffix`
   / `multi-id-marker` / `multi-id-marker-with-suffix`）に分けるだけで実現できる。
4. **bash glob の特性活用**: 単記パスでは `[[ "$subject" == "${canonical} (#"*")" ]]` で
   prefix + 任意 + 閉じ括弧という構造を 1 行で粗判定し、続けて `${var#prefix}` /
   `${var%)}` のパラメータ展開で `<number>` 部を抽出してから `=~ ^[0-9]+$` で厳密検証
   する 2 段階構成を取った。これにより task_id の `.` などのメタ文字を意識せずに済む
   （glob `*` の前後は quote 済みのリテラル文字列）。

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `local-watcher/bin/issue-watcher.sh` | `pt_resolve_diff_range` 関数の単記 / 連記いずれの照合パスでも canonical suffix `(#<digits>)` を optional として許容。新 via タグ `single-id-marker-with-suffix` / `multi-id-marker-with-suffix` を追加し、stderr ログに出力。関数ヘッダ doc を Issue #421 Req 1〜5 反映で更新 |
| `local-watcher/test/pt_resolve_diff_range_test.sh` | 新規追加（既存 `pt_post_marker_classify_test.sh` の awk 抽出 + eval パターン踏襲）。Req 1〜5 / NFR 1.1 をカバーする 50 アサーション |

## AC Traceability

| Requirement | テスト（test_file:section） | 備考 |
|-------------|---------------------------|------|
| Req 1.1 | `pt_resolve_diff_range_test.sh:Section A` (suffix 付き 単記 marker / 初回 task) | 解決成功と range pair を確認 |
| Req 1.2 | `pt_resolve_diff_range_test.sh:Section A` (混在 順方向 / 逆方向) | 時系列最終一致が一意に採用される |
| Req 1.3 | `pt_resolve_diff_range_test.sh:Section D Req 4.5` (非数字 / 数字混在) | `<number>` を `^[0-9]+$` で厳密検証 |
| Req 1.4 | `pt_resolve_diff_range_test.sh:Section D Req 4.1〜4.4` | canonical 表記の境界を網羅 |
| Req 1.5 | `pt_resolve_diff_range_test.sh:Section A` (`via=single-id-marker-with-suffix` 観測) | 観測タグの出力を確認 |
| Req 2.1 | `pt_resolve_diff_range_test.sh:Section B` (slash / comma 連記 suffix 付き) | 連記 suffix 付き marker の解決 |
| Req 2.2 | `pt_resolve_diff_range_test.sh:Section B Req 2.2` (誤マッチ防止) | token 化規則を suffix 有無で同一適用 |
| Req 2.3 | `pt_resolve_diff_range_test.sh:Section B` (`via=multi-id-marker-with-suffix`) | 単記タグとの区別を確認 |
| Req 3.1 | `pt_resolve_diff_range_test.sh:Section C Req 3.1` | suffix 無し 単記の SHA pair 一致 |
| Req 3.2 | `pt_resolve_diff_range_test.sh:Section C Req 3.2` | 既存 `via=multi-id-marker` の維持 |
| Req 3.3 | `pt_resolve_diff_range_test.sh:Section A/C` (`-with-suffix` 不出力) | 既存ログタグの文字列形式と発火条件を温存 |
| Req 4.1 | `pt_resolve_diff_range_test.sh:Section D Req 4.1` | 解決する |
| Req 4.2 | `pt_resolve_diff_range_test.sh:Section D Req 4.2` | 空白なし → 解決しない |
| Req 4.3 | `pt_resolve_diff_range_test.sh:Section D Req 4.3` | 括弧なし → 解決しない |
| Req 4.4 | `pt_resolve_diff_range_test.sh:Section D Req 4.4` | 追加文字列 → 解決しない |
| Req 4.5 | `pt_resolve_diff_range_test.sh:Section D Req 4.5 / 4.5 (mixed)` | 非数字 / 数字混在 → 解決しない |
| Req 4.6 | `pt_resolve_diff_range_test.sh:Section D Req 4.6 x2` | 連記パスにも同一規則を適用 |
| Req 5.1 | `pt_resolve_diff_range_test.sh:Section E Req 5.1 x2` | marker 不在 / 該当 task_id 不在で rc=1 |
| Req 5.2 | （observation） | 失敗時挙動は本変更で touch しないため、`mark_issue_failed` 経由の既存契約を維持 |
| NFR 1.1 | `pt_resolve_diff_range_test.sh:Section C` | 既存タグの文字列・発火条件を変更しないことを観測 |
| NFR 1.2 | （observation） | `PER_TASK_LOOP_ENABLED` gate は本関数の呼び出し元（既存）で制御されており、本関数自体は gate 外で評価しない |
| NFR 2.1 | `pt_resolve_diff_range_test.sh:Section A/B` | `via=*-with-suffix` タグの grep 可能性を確認 |
| NFR 2.2 | （observation） | 解決失敗は `pt_resolve_diff_range` の rc=1 を呼び出し元が `pt_mark_diff_range_resolve_failed` で診断する既存経路。本関数自体は失敗時に新規ログ追加しない |
| NFR 3.1 | `pt_resolve_diff_range_test.sh:Section D Req 4.5` | `<number>` を `^[0-9]+$` で検証してから採用 |
| NFR 3.2 | コードレビュー観点 | 量指定子は `[0-9]+`（線形時間）に限定。`(.+) as done( \(#[0-9]+\))?$` は末尾アンカで境界を固定しているため ReDoS リスクなし |
| NFR 4.1 | `pt_resolve_diff_range_test.sh:Section D` | 5 パターン（許容 1 / 拒否 4）を fixture で網羅 |
| NFR 4.2 | 既存 `pt_*_test.sh` 全 4 ファイル | 既存テスト全 101 件 (18+24+20+39) パス維持 |

## 静的解析

- `shellcheck local-watcher/bin/issue-watcher.sh` → クリーン（出力 0 行）
- `shellcheck local-watcher/test/pt_resolve_diff_range_test.sh` → クリーン
- `bash -n local-watcher/bin/issue-watcher.sh` → syntax OK
- `diff -r .claude/agents repo-template/.claude/agents` → 空（変更なし）
- `diff -r .claude/rules repo-template/.claude/rules` → 空（変更なし）

## テスト結果

- `bash local-watcher/test/pt_resolve_diff_range_test.sh` → **PASS: 50, FAIL: 0**
- 既存 pt_*_test.sh 4 ファイル → 全 PASS（合計 PASS: 101, FAIL: 0）

## 確認事項

なし。requirements.md の Out of Scope に「Developer 側 prompt の suffix 付与禁止化」「`(#<number>)`
以外の trailing suffix 形式」「retrofit」が明示されており、本実装はそれに準拠して watcher 側の
許容拡大のみを行った。design.md / tasks.md は本 Issue では生成されていないが、Triage が
`needs_architect: false` と判定したと推測される（regex / glob の局所変更で完結する scope）。

STATUS: complete
