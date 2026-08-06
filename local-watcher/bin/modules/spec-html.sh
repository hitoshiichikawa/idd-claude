#!/usr/bin/env bash
# spec-html.sh — 人間レビュー用成果物の HTML 並行生成モジュール（#526）
#
# 用途:
#   opt-in（`SPEC_HTML_ENABLED=true`）有効時に、design / impl 完了直後の fail-open
#   hook（slot-worker.sh `_slot_run_issue`）から呼ばれ、対象 spec ディレクトリ
#   `docs/specs/<番号>-<slug>/` 配下の人間レビュー用 .md 成果物（requirements.md /
#   design.md / tasks.md / impl-notes.md / review-notes.md）に対応する .html を
#   並行生成する fail-open orchestrator（Req 1.2, 2.x, 4.x, 5.x, 6.1）。
#
#   .md は正準（source of truth）として **一切書き換えず**（.html のみ Write /
#   Req 3.1）、機械ゲート / エージェント連携は .html に依存しない（本 module は
#   .html を **読む**経路を持たない）。生成失敗は本流へ伝播させず（常に return 0 /
#   Req 5.1, 5.3）、外部ネットワーク / gh を呼ばない（ローカル生成 / Req 6.1）。
#
#   公開関数（prefix `shx_` / family 非該当の単独 module）:
#   - shx_log / shx_warn / shx_error : `spec-html:` prefix の grep 可能 3 段 logger
#   - shx_enabled                    : `SPEC_HTML_ENABLED == "true"` 厳密一致 gate（副作用なし）
#   - shx_render_available           : `command -v "$SPEC_HTML_RENDER_BIN"`。不在で warn + 1
#   - shx_target_files               : basename allowlist の実在 regular file を絶対パス列挙
#   - shx_html_path                  : `<name>.md` → `<name>.html` を導出する純粋関数
#   - shx_render_one                 : 1 ファイルを SPEC_HTML_RENDER_CMD + timeout で変換
#   - shx_run_for_spec_dir           : 唯一のエントリ。gate→available→列挙→変換。常に return 0
#
# 配置先:
#   $HOME/bin/modules/spec-html.sh（install.sh が local-watcher/bin/modules/ から
#   `*.sh` glob で配置する。新 module 追加による installer 変更は不要）。
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#     `set -euo pipefail` は本体側で宣言済みのため、本モジュールは関数定義のみを持ち
#     トップレベル副作用を持たない（module loader の前提）。
#   - 実行時 global 参照（遅延束縛 / 本体 Config・Slot Runner が設定済み）:
#     $REPO / $REPO_DIR / $SPEC_DIR_REL / $NUMBER（ログ用）/ $SPEC_HTML_ENABLED /
#     $SPEC_HTML_RENDER_BIN / $SPEC_HTML_RENDER_CMD / $SPEC_HTML_TIMEOUT /
#     $SPEC_HTML_TARGETS（すべて watcher-config.sh で定義・正規化済み）。
#   - 外部 CLI: `SPEC_HTML_RENDER_BIN`（既定 `pandoc`）/ `timeout`（coreutils）。
#     render CLI 不在時は skip + warn で本流継続（Req 5 / NFR 2）。
#   - call site（design / impl 分岐 rc=0 直後の `shx_run_for_spec_dir || true`）は
#     実行順序温存のため slot-worker.sh 側に残る。
#
# セットアップ参照先:
#   README.md（オプション機能一覧 / ディレクトリ構成） / install.sh（配置ロジック）
#   設計参照: docs/specs/526-feat-agents-html-md/design.md

# spec-html 専用ロガー（既存 tc_log / sav_log と同形式）。
# 行頭 `[YYYY-MM-DD HH:MM:SS] [$REPO] spec-html:` の 3 段 prefix を維持し、
# `grep '\[.*\] spec-html:'` で全件抽出可能（NFR 3.1）。log は stdout、warn/error は stderr。
shx_log() {
  echo "[$(date '+%F %T')] [$REPO] spec-html: $*"
}
shx_warn() {
  echo "[$(date '+%F %T')] [$REPO] spec-html: WARN: $*" >&2
}
shx_error() {
  echo "[$(date '+%F %T')] [$REPO] spec-html: ERROR: $*" >&2
}

# ─── shx_enabled ───
#
# opt-in gate 判定（Req 1.1, 1.2）。`SPEC_HTML_ENABLED` が `true` に厳密一致する
# ときのみ rc 0。それ以外（未設定 / `false` / typo 等）は rc 1。
# watcher-config.sh で `true` / `false` の 2 値に正規化済みだが、defensive に
# `:-false` を付す。副作用なし（純粋判定）。
#
# 戻り値: 0 = 有効 / 1 = 無効
shx_enabled() {
  [ "${SPEC_HTML_ENABLED:-false}" = "true" ]
}

# ─── shx_render_available ───
#
# md→html 変換 CLI の可用性判定（Req 5 / NFR 2）。`command -v "$SPEC_HTML_RENDER_BIN"`
# が真なら rc 0。偽なら skip 理由を 1 行 warn（NFR 3.1）して rc 1 を返し、
# 呼び出し側（shx_run_for_spec_dir）が本流を止めずに skip する。
#
# 戻り値: 0 = 利用可能 / 1 = 不在（warn 記録済み）
shx_render_available() {
  if command -v "${SPEC_HTML_RENDER_BIN:-pandoc}" >/dev/null 2>&1; then
    return 0
  fi
  shx_warn "render CLI 不在 bin='${SPEC_HTML_RENDER_BIN:-pandoc}' — .html 生成を skip（本流は継続 / Req 5）"
  return 1
}

# ─── shx_html_path ───
#
# `.html` パス導出（純粋関数 / Req 2.4）。`<name>.md` → `<name>.html`（同一 dir）。
# 末尾が `.md` でない場合は `.html` を付加する（防御的挙動。通常は allowlist の
# `*.md` のみが渡る）。
#
# 入力: 第 1 引数 = .md の絶対パス
# stdout: 対応する .html の絶対パス（改行なし）
# 戻り値: 常に 0 / 副作用: なし
shx_html_path() {
  local md_path="$1"
  printf '%s' "${md_path%.md}.html"
}

# ─── shx_target_files ───
#
# 並行生成対象の .md を列挙する（Req 2.2, 2.3 / NFR 5.1）。`SPEC_HTML_TARGETS`
# （space 区切り basename allowlist）のうち、spec dir に **実在する regular file**
# のみを絶対パスで 1 行 1 パス stdout に出力する。存在しないもの（design 段では
# impl-notes.md / review-notes.md が未生成など）は黙って除外し、エラーにしない。
#
# 未信頼入力対策（NFR 5.1）: spec dir path は `REPO_DIR` + `SPEC_DIR_REL`
# （NUMBER は `^[0-9]+$` 既検証）+ 固定 basename allowlist から構成し、変数は全 quote。
# allowlist エントリに path separator（`/`）や `..` が混入した異常値は列挙から除外する
# （path 横断予防）。
#
# 入力: global $REPO_DIR / $SPEC_DIR_REL / $SPEC_HTML_TARGETS
# stdout: 実在対象 .md の絶対パス（改行区切り）
# 戻り値: 常に 0（副作用なし。pure read）
shx_target_files() {
  local spec_dir="${REPO_DIR:-}/${SPEC_DIR_REL:-}"
  local -a targets=()
  read -ra targets <<< "${SPEC_HTML_TARGETS:-}"
  local t path
  for t in "${targets[@]:-}"; do
    [ -n "$t" ] || continue
    # basename allowlist: path separator / `..` / 単独ドットを含むエントリは除外（NFR 5.1）
    case "$t" in
      */*|*..*|.|"") continue ;;
    esac
    path="$spec_dir/$t"
    if [ -f "$path" ] && [ -r "$path" ]; then
      printf '%s\n' "$path"
    fi
  done
  return 0
}

# ─── shx_render_one ───
#
# 1 ファイルを .md → .html へ変換する（Req 2.5, 4.2, 5.2）。`SPEC_HTML_RENDER_CMD`
# テンプレをトークン分割し、各トークンの `{IN}` / `{OUT}` を対象 .md / .html の実
# パスへ置換してから `timeout "$SPEC_HTML_TIMEOUT"` 付きで実行する。
#
# 置換をトークン分割の **後**に行うため、置換値（path）がスペースを含んでも再分割
# されず、テンプレ側の意図しない語増殖・引数注入を防ぐ（NFR 5.1）。`.md` は入力
# としてのみ参照し書き換えない（.html のみ生成 / Req 3.1）。既存 .html は無条件で
# 上書きし、手編集を維持しない（派生物 / Req 4.2）。
#
# 入力: 第 1 引数 = 対象 .md の絶対パス
# 戻り値: 0 = 変換成功（.html 生成）/ 非 0 = 失敗（対象ファイル名付き warn 記録済み）
shx_render_one() {
  local md_path="$1"
  local html_path
  html_path="$(shx_html_path "$md_path")"
  local -a cmd_parts=() cmd=()
  read -ra cmd_parts <<< "${SPEC_HTML_RENDER_CMD:-}"
  # 空 / 空白のみの render cmd は変換不能。ここで弾かないと空トークン実行で
  # 誤った rc（127 等）になる（`"${arr[@]:-}"` の空要素注入も回避するため件数で判定）。
  if [ "${#cmd_parts[@]}" -eq 0 ]; then
    shx_warn "render 失敗 file='$(basename -- "$md_path")' reason=empty-render-cmd"
    return 1
  fi
  local part
  for part in "${cmd_parts[@]}"; do
    part="${part//\{IN\}/$md_path}"
    part="${part//\{OUT\}/$html_path}"
    cmd+=("$part")
  done
  local rc=0
  timeout "${SPEC_HTML_TIMEOUT:-60}" "${cmd[@]}" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    shx_warn "render 失敗 file='$(basename -- "$md_path")' rc=${rc}（本流は継続 / Req 5.1, 5.2）"
    return "$rc"
  fi
  shx_log "render 成功 file='$(basename -- "$md_path")' -> '$(basename -- "$html_path")'"
  return 0
}

# ─── shx_run_for_spec_dir ───
#
# 唯一のエントリポイント（Req 1.1, 1.2, 1.4, 2.1, 4.1, 5.1, 5.3 / NFR 3.1）。
# slot-worker.sh の design / impl 分岐 rc=0 直後から `shx_run_for_spec_dir || true`
# で呼ばれる。
#
# 順序:
#   1. shx_enabled が偽（gate OFF）→ **ログ副作用ゼロ**で return 0（既定 OFF の
#      観測可能挙動を導入前と完全一致させる / Req 1.4 / NFR 1.1）
#   2. shx_render_available が偽（CLI 不在）→ warn 記録済みで return 0（skip / Req 5）
#   3. 実在対象 .md を列挙し、各 .md を shx_render_one で変換（失敗は per-file warn で
#      継続し次対象へ）
#   4. 成功 / 失敗件数の summary を 1 行 log（NFR 3.1）
#
# 不変条件: **常に return 0**（本流の exit code に影響しない / Req 5.3）。gate OFF /
# CLI 不在 / 生成失敗のいずれでも本流を止めない。
#
# 入力: global（shx_* 各関数が参照する env / path）
# 戻り値: 常に 0
# 副作用: gate ON かつ CLI 可用時のみ .html を Write + ログ書き込み
shx_run_for_spec_dir() {
  # 1. gate OFF → 無ログ no-op（NFR 1.1 / Req 1.4）
  if ! shx_enabled; then
    return 0
  fi
  # 2. CLI 不在 → skip（warn は shx_render_available が記録済み / Req 5）
  if ! shx_render_available; then
    return 0
  fi
  # 3. 実在対象を列挙して各変換
  local md total=0 ok=0 fail=0
  while IFS= read -r md; do
    [ -n "$md" ] || continue
    total=$((total + 1))
    if shx_render_one "$md"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done < <(shx_target_files)
  # 4. summary log（NFR 3.1）
  shx_log "issue=#${NUMBER:-?} 完了 dir='${SPEC_DIR_REL:-?}' targets=${total} ok=${ok} fail=${fail}"
  return 0
}
