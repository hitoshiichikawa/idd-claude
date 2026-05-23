# 実装ノート: #168 macOS gtimeout 透過フォールバック

## 実装概要

`local-watcher/bin/issue-watcher.sh` の前提ツールチェック（旧 441 行目
`for cmd in gh jq claude git flock timeout; do`）の **直前** に gtimeout フォールバックを
確立する。

### 変更点

1. **gtimeout フォールバック関数の定義**（前提チェックより前 / Req 1.3）

   ```bash
   if ! command -v timeout >/dev/null 2>&1 && command -v gtimeout >/dev/null 2>&1; then
     # shellcheck disable=SC2317  # 関数本体は後続の `timeout ...` 呼び出しから実行される
     timeout() { gtimeout "$@"; }
     export -f timeout
   fi
   ```

2. **前提ツールチェックから `timeout` を分離**

   - 共通ループ `for cmd in gh jq claude git flock; do ...` から `timeout` を外した
   - `timeout` は専用チェックに分離し、フォールバック関数定義込みで `command -v timeout` を判定
   - 不在時のエラーメッセージに macOS 向けの `brew install coreutils` 解決手順を追加（Req 3.3）

### export -f を使ったか否かと根拠

**使った（`export -f timeout`）。**

- 全 `timeout` 呼び出しパスを調査した結果（後述）、`bash -c "$cmd"` 経由（9033 行目の Stage A
  verify）の `$cmd`（= `STAGE_A_VERIFY_COMMAND`、ユーザー定義の検証コマンド）の中で現状
  `timeout` を呼ぶ箇所は無い。したがって export -f が **無くても現状の全パスは動作する**。
- ただし requirements.md の **Req 2.3**（`bash -c` 経由で起動される検証コマンド内の `timeout`
  呼び出しを `gtimeout` に解決する）を観測可能な形で満たすため、安全側に倒して `export -f timeout`
  を併用した。これにより、将来 `STAGE_A_VERIFY_COMMAND` 等の `bash -c` 経由コマンド内で
  `timeout` が使われた場合でも子 bash に関数が継承され、フォールバックが一貫して効く。
- `export -f` は bash 固有機能だが、本スクリプトは shebang `#!/usr/bin/env bash` かつ
  `set -euo pipefail` の bash 前提実装であり問題ない（POSIX sh では動作しないが対象外）。
- スモークテストで `bash -c 'timeout 5 echo X'` が `GTIMEOUT_CALLED` になることを実証済み
  （export -f なしでは子 bash に関数が継承されず本物の timeout 探索に失敗する）。

## export -f 要否の調査結果（全 timeout 呼び出しパスの分類）

`grep -ni timeout` で全呼び出し箇所を抽出し、フォールバック（シェル関数）が効くかで分類:

| パス種別 | 該当例（行） | 関数フォールバックが効くか | 根拠 |
|---|---|---|---|
| コマンド置換 `$(timeout ...)` | 1109, 1247, 2930, 3009, 8545, 8712 ほか多数 | **効く** | 同一シェル内で関数解決される（Req 2.1） |
| 直接呼び出し `timeout ...` | 1182, 1549, 2978, 3527, 9855, 10396 ほか多数 | **効く** | 同一シェルなので関数が優先される |
| サブシェル `( ... timeout ... )` | 9033 `(cd "$REPO_DIR" && timeout ... bash -c "$cmd")` | **効く** | サブシェルは親シェルの関数を継承（Req 2.2） |
| バックグラウンド fork `( ... ) &` | — （該当の timeout 呼び出しは確認されず） | **効く** | fork した子シェルにも関数は継承（Req 2.2、スモークで実証） |
| オプション付き `timeout --kill-after=10 ...` | 9033 | **効く** | 関数は `"$@"` で全引数を gtimeout へ透過（Req 2.4、スモークで実証） |
| `bash -c "$cmd"` 内の timeout | **該当なし**（`$cmd` = STAGE_A_VERIFY_COMMAND） | export -f が **必要** | 子 bash は関数を継承しないため、`export -f timeout` で対処（Req 2.3、防御的措置） |

- `bash -c` / `sh -c` の全出現を grep した結果、`bash -c "$cmd"` は 9033 行のみで、その `$cmd`
  は watcher 内部で組み立てた `timeout` 文字列ではなく外部の検証コマンド（npm test 等）。
  外部スクリプト経由で watcher の `timeout` 関数を必要とする起動経路は確認されなかった。
- 結論: 現状の全パスは関数フォールバックのみで動作するが、Req 2.3 を満たし将来の回帰を防ぐ
  ため `export -f timeout` を併用した（オーバーヘッドは無視できる）。

## command -v timeout で分岐するヘルパー関数との相互作用（確認事項 2）

- `verify_pushed_or_retry`（8541-8543）と Stage C verify（8685-8687）は
  `if command -v timeout ...; then _git_timeout=(timeout 30); fi` で timeout 有無を実行時に判定する。
- これらは **実行時** に呼ばれる関数であり、フォールバック関数定義（スクリプト冒頭の前提
  チェック直前）より後に評価される。順序問題はない。
- macOS（timeout 不在 / gtimeout あり）ではフォールバック関数定義後に `command -v timeout` が
  function として true を返すため、これらヘルパーは macOS でも `(timeout 30)` 経由（実体は
  gtimeout）になる。これは requirements Req 2（全パスで有効）の方向と整合する **望ましい変化**。
  Linux（timeout 実体あり）では従来通り file として true を返すため挙動不変。

## 実施した検証手順と結果

### 静的解析

- `bash -n local-watcher/bin/issue-watcher.sh` → SYNTAX_OK
- `shellcheck local-watcher/bin/issue-watcher.sh` → 警告数は変更前後ともに **43 件で同一**
  （新規警告ゼロ）。追加した `timeout()` 関数の SC2317（unreachable 誤検知）は
  `# shellcheck disable=SC2317` で justify 済み。残る 43 件はすべて既存コードの info レベル
  （SC2317 / SC2012）。

### スモークテスト（擬似 gtimeout を /tmp に配置して検証）

- **Scenario 1**（timeout 不在 / gtimeout のみ）: PATH から timeout を完全に除去し擬似
  gtimeout のみを置いた環境で、以下すべてが `GTIMEOUT_CALLED` に解決されることを確認:
  - Req 1.1/2.1 コマンド置換 `$(timeout 5 echo X)` → GTIMEOUT_CALLED
  - Req 2.2 サブシェル `( timeout 5 echo X )` → GTIMEOUT_CALLED
  - Req 2.2 バックグラウンド fork `( timeout 5 echo X ) &` → GTIMEOUT_CALLED
  - Req 2.4 オプション付き `timeout --kill-after=10 5 echo X` → `args=--kill-after=10 5 echo X`
  - Req 2.3 `bash -c 'timeout 5 echo X'` → GTIMEOUT_CALLED（export -f の効果を実証）
- **Scenario 2**（timeout 存在環境 / NFR 1.1・1.2）: 本物の timeout がある PATH では
  フォールバック関数を定義せず `type -t timeout` が `file` を返す（関数は定義されない）。
- **Scenario 3**（timeout・gtimeout ともに不在 / Req 3.1・3.2・3.3）: 両方不在の PATH で
  exit code 1、stderr に「timeout コマンドが見つかりません」と「brew install coreutils」案内を出力。

### dry run（前提チェック通過後の早期 return 非破壊）

- `REPO=owner/test REPO_DIR=<本 worktree> TRIAGE_TEMPLATE=/nonexistent` で起動 →
  前提ツールチェック（timeout 含む）を通過し、Triage テンプレート不在チェックに到達して exit 1。
  前提チェックロジックを壊していないことを確認。

## README 更新（Req 4）

`README.md` の 2 箇所を更新:

- macOS 依存記述（Local watcher 方式の前提、108 行目付近）: `timeout` / `gtimeout` 自動検出
  フォールバックの旨を追記（Req 4.1 / 4.2）
- Phase A migration note（1314 行目付近）: gtimeout 自動フォールバック・手動リンク不要・
  両方不在時の明示エラー停止を追記（Req 4.1 / 4.2）

## 受入基準とテストの対応

| Req ID | 担保したテスト / 検証 |
|---|---|
| 1.1 | Scenario 1: timeout 不在 / gtimeout のみで `command -v timeout` が解決し全呼び出しが GTIMEOUT_CALLED |
| 1.2 | dry run: 前提ツールチェックを通過し起動継続（Triage チェックに到達） |
| 1.3 | コード配置: フォールバックを前提チェックループの直前に定義（行順で確認） |
| 2.1 | Scenario 1 コマンド置換が GTIMEOUT_CALLED |
| 2.2 | Scenario 1 サブシェル / バックグラウンド fork が GTIMEOUT_CALLED |
| 2.3 | Scenario 1 `bash -c 'timeout ...'` が GTIMEOUT_CALLED（export -f の効果） |
| 2.4 | Scenario 1 `--kill-after=10` 付き呼び出しでオプションが gtimeout に透過 |
| 3.1 | Scenario 3: stderr に「timeout コマンドが見つかりません」 |
| 3.2 | Scenario 3: exit code 1（非ゼロ） |
| 3.3 | Scenario 3: エラーに「brew install coreutils」案内を含む |
| 4.1 | README の macOS 依存記述・migration note に自動検出フォールバックを記載 |
| 4.2 | README に `brew install coreutils` 案内を記載 |
| NFR 1.1 | Scenario 2: timeout 存在環境ではフォールバック関数を定義しない（type -t = file） |
| NFR 1.2 | shellcheck 警告数不変 + dry run で起動可否・exit code・ログ出力を確認 |
| NFR 1.3 | env var 名（`MERGE_QUEUE_GIT_TIMEOUT` / `STAGE_A_VERIFY_TIMEOUT` 等）は一切変更せず |
| NFR 2.1 | gtimeout はフォールバック条件（timeout 不在かつ gtimeout 存在）でのみ利用。新規必須依存を増やさない |

## 確認事項（Reviewer 判断ポイント）

1. **export -f の採用**: 現状の全パスは関数フォールバックのみで動作するため export -f は厳密
   には不要だが、Req 2.3（`bash -c` 経由）を観測可能な形で満たし将来の回帰を防ぐため併用した。
   この防御的措置の妥当性を確認いただきたい。
2. **timeout を前提チェックループから分離**: timeout 専用のエラーメッセージ（brew install
   coreutils 案内 / Req 3.3）を出すため、共通ループから timeout を分離した。共通ループの
   汎用メッセージ（「PATH を確認してください」）は他コマンド（gh/jq/claude/git/flock）に対して
   従来通り維持している。
3. **shellcheck SC2317 の disable**: 追加した `timeout()` 関数本体に対する SC2317（unreachable
   誤検知）を `# shellcheck disable=SC2317` で抑制した。既存コードにも同種の SC2317 info が
   多数あり、本変更で警告総数は不変（43 件）。

STATUS: complete
