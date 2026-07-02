#!/usr/bin/env bash
# shellcheck shell=bash
# pr-iteration-state.sh — PR body hidden marker の read/write + round outcome / no-progress streak
#
# family: pr-iteration / prefix: pi_（#469 で pr-iteration.sh から分割。family マニフェストは
#   pr-iteration.sh 冒頭ヘッダを参照）
#
# 用途:
#   PR body の hidden marker
#   （<!-- idd-claude:pr-iteration round=N last-run=... no-progress-streak=K -->）の
#   読み取り / 書き込みと、round 終了時の outcome 分類 / HEAD SHA 比較 / no-progress 連続
#   カウンタ算出を担う。SHA ベース streak を扱い、内容ベース（oos）streak は
#   pr-iteration-oos.sh に分離している。
#   - marker read: pi_read_round_counter / pi_read_no_progress_streak / pi_read_last_run
#   - marker write: pi_write_marker / pi_post_processing_comment / pi_post_processing_marker
#   - round outcome / streak（純粋関数）: pi_classify_round_outcome / pi_round_commit_pushed /
#     pi_next_no_progress_streak
#
# 配置先:
#   $HOME/bin/modules/pr-iteration-state.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - ロガー pi_log / pi_warn は core_utils.sh。グローバル（$REPO / $PR_ITERATION_GIT_TIMEOUT /
#     $PR_ITERATION_MAX_ROUNDS / $PR_ITERATION_OOS_ENABLED 等）は watcher-config.sh。
#   - 外部 CLI: gh / jq / date / git。

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_round_counter: PR body から hidden marker の round 数を取得
#   入力: $1=pr_number
#   出力: stdout に round 数（marker 無しなら 0）
#   AC 7.1, 7.4
# ─────────────────────────────────────────────────────────────────────────────
pi_read_round_counter() {
  local pr_number="$1"
  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、round=0 として扱います"
    echo "0"
    return 0
  fi
  # marker 形式: <!-- idd-claude:pr-iteration round=N last-run=... -->
  # 複数検出時は最後（最新）の数値を採用 = fail-safe
  local round
  round=$(echo "$body" \
    | grep -oE 'idd-claude:pr-iteration round=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${round:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_no_progress_streak: PR body から hidden marker の no-progress 連続カウンタを取得
#   入力: $1=pr_body (gh pr view --json body --jq '.body // ""' で取得済みの文字列)
#   出力: stdout に整数（key 不在 / marker 不在なら "0"）
#   返り値: 0 固定
#   Issue #122 Req 3.6 / 4.2 / 4.4 / 4.5
#
#   marker 形式: <!-- idd-claude:pr-iteration round=N last-run=ISO8601 no-progress-streak=K -->
#   既存 marker（no-progress-streak キー無し）の場合は "0" を返す（Req 4.2 / 4.4 後方互換）。
#   複数 marker がある場合は末尾を採用（既存 pi_read_round_counter / pi_read_last_run と整合）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_no_progress_streak() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo "0"
    return 0
  fi
  local streak
  streak=$(echo "$pr_body" \
    | grep -oE 'idd-claude:pr-iteration [^>]*no-progress-streak=[0-9]+' \
    | grep -oE 'no-progress-streak=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${streak:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_last_run: PR body から hidden marker の last-run ISO8601 タイムスタンプを抽出
#   入力: $1=pr_body（gh pr view --json body --jq '.body // ""' で取得済みの文字列）
#   出力: stdout に last-run の ISO8601 文字列（例: "2026-04-25T12:34:56Z"）。
#         marker / last-run キーが無ければ空文字列を出力。
#   返り値: 0 固定（呼び出し元で空文字列を初回 round 扱いにする）
#   AC #55 Req 2.3, 2.4 / 4.1
#
#   marker 形式: <!-- idd-claude:pr-iteration round=N last-run=ISO8601 -->
#   複数検出時は最後（最新）の値を採用（pi_read_round_counter の `tail -1` と整合）。
#   読み取り専用であり、書き込み側は pi_post_processing_marker のまま温存（後方互換性）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_last_run() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo ""
    return 0
  fi
  local last_run
  # 1. marker 行を抽出 → 2. `last-run=...` 部分のみを抽出 → 3. 末尾を採用
  #    値部分はスペース・`>` 以外を許容（pi_post_processing_marker は ISO8601 UTC を打刻するが、
  #    fail-safe としてスペース直前 / `>` 直前まで拾う）。
  last_run=$(echo "$pr_body" \
    | grep -oE 'idd-claude:pr-iteration round=[0-9]+ last-run=[^ >]+' \
    | sed -E 's|.*last-run=||' \
    | tail -1)
  echo "${last_run:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_marker: PR body に hidden marker を書き込み + 着手表明コメント投稿
#   入力: $1=pr_number, $2=new_round
#   AC 6.1, 7.1
#   戻り値: 0=成功, 1=失敗（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# pi_write_marker: PR body の hidden marker を round + last-run + no-progress-streak
#   の 3 フィールド形式で書き換える（Issue #122 Req 4.1 / 4.3 / 4.5）。
#   入力: $1=pr_number, $2=round, $3=no_progress_streak
#         $4=oos_no_progress_streak（省略可 / #437 Req 5）, $5=oos_fingerprint（省略可 / #437 Req 5）
#   戻り値: 0=成功, 1=失敗（呼び出し元で WARN + 据え置き、Req 5.4）
#
#   設計判断:
#     - marker prefix `<!-- idd-claude:pr-iteration ` と既存キー名 `round` / `last-run`
#       は変更しない（Req 4.3 / NFR 1.2）。`no-progress-streak=K` を末尾に追加。
#     - 既存 marker の置換 sed は `last-run=[^>]*` で末尾 `-->` 直前まで全部食うため、
#       旧フォーマット（no-progress-streak 無し）も同じ正規表現で吸収できる（Req 4.4）。
#     - 副作用なし（PR body 書き込み 1 回のみ。コメント投稿は呼び出し元で別途実施）。
#     - Issue #437 Req 5 / NFR 1.3: gate ON（PR_ITERATION_OOS_ENABLED=true）かつ第 4/5 引数が
#       渡されたときのみ、marker 末尾に `oos-no-progress-streak=J oos-fingerprint=<H>` を追記する。
#       gate OFF（既定）/ 引数未指定では 3 フィールドのまま既存 marker と byte 互換（NFR 1.3）。
#       既存 sed `[^>]*` は oos フィールド有無の旧 marker も吸収するため後方互換（旧フォーマット
#       吸収）。
# ─────────────────────────────────────────────────────────────────────────────
pi_write_marker() {
  local pr_number="$1"
  local round="$2"
  local streak="$3"
  local oos_streak="${4-}"
  local oos_fingerprint="${5-}"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、marker 更新をスキップ"
    return 1
  fi

  # gate ON かつ oos フィールドが渡されたときのみ 5 フィールド形式に拡張する。
  # gate OFF / 引数未指定では既存 3 フィールド形式で byte 互換（NFR 1.3）。
  local oos_suffix=""
  if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ] && [ -n "$oos_streak" ]; then
    oos_suffix=" oos-no-progress-streak=${oos_streak} oos-fingerprint=${oos_fingerprint}"
  fi
  local marker="<!-- idd-claude:pr-iteration round=${round} last-run=${now} no-progress-streak=${streak}${oos_suffix} -->"
  local new_body
  if echo "$body" | grep -qE 'idd-claude:pr-iteration round=[0-9]+'; then
    # 既存 marker を最新 marker で置換（複数あった場合も全部 1 つに集約）。
    # `last-run=[^>]*` は末尾 `-->` 直前まで貪欲に食うため、no-progress-streak 有無の
    # どちらの旧 marker も同じ regex で置換できる（Req 4.4）。
    new_body=$(echo "$body" | sed -E "s|<!-- idd-claude:pr-iteration round=[0-9]+ last-run=[^>]*-->|${marker}|g")
  else
    # 末尾に追記（前置の改行で見やすく）
    new_body="${body}

${marker}"
  fi

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --body "$new_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: PR body の hidden marker 更新に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_comment: round 着手表明コメントを投稿する（marker 書き込みなし）
#   入力: $1=pr_number, $2=new_round, $3=max_rounds (表示用、`0`=無制限表記)
#   戻り値: 0 固定（コメント投稿失敗は WARN のみ。ラベル誤遷移リスクが無いため
#           round 全体を失敗扱いにはしない / NFR 1.1 既存挙動踏襲）
#   Issue #122 Req 1.6 / 2.4
#
#   設計判断:
#     - 既存 pi_post_processing_marker は「marker 書き込み + コメント投稿」の合成だったが、
#       #122 で「失敗 round では marker を据え置く」（Req 5）が必要になったため、
#       marker 書き込みは round 終了時に成功 path でのみ行うよう分離した。
#     - コメントは round 開始時の人間向け視認用なので、claude 実行前に投稿する
#       （既存挙動 NFR 1.1 と等価）。
# ─────────────────────────────────────────────────────────────────────────────
pi_post_processing_comment() {
  local pr_number="$1"
  local new_round="$2"
  local max_rounds="${3:-$PR_ITERATION_MAX_ROUNDS}"

  local max_display
  if [ "$max_rounds" = "0" ]; then
    max_display="無制限"
  else
    max_display="$max_rounds"
  fi
  local processing_msg
  processing_msg=$(printf '%s\n%s' \
    ":robot: PR Iteration Processor が処理を開始しました (round ${new_round}/${max_display})。" \
    "<!-- idd-claude:pr-iteration-processing round=${new_round} -->")
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$processing_msg" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: 着手表明コメントの投稿に失敗"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_marker: PR body に hidden marker を書き込み + 着手表明コメント投稿
#   （Issue #26 / #35 で導入された合成関数。互換性のため温存するが、Issue #122 以降の
#   pi_run_iteration は pi_write_marker / pi_post_processing_comment を直接呼ぶ。
#   外部から本関数を呼んでいる箇所が無いことを確認済み 2026-05 時点）
#   入力: $1=pr_number, $2=new_round, $3=streak (省略時 0 / 後方互換)
#         $4=max_rounds (表示用、省略時 PR_ITERATION_MAX_ROUNDS / 後方互換)
#   AC 6.1, 7.1 / Issue #122 Req 4.1 / 6.1
#   戻り値: 0=成功, 1=失敗（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
pi_post_processing_marker() {
  local pr_number="$1"
  local new_round="$2"
  local streak="${3:-0}"
  local max_rounds="${4:-$PR_ITERATION_MAX_ROUNDS}"

  if ! pi_write_marker "$pr_number" "$new_round" "$streak"; then
    return 1
  fi
  pi_post_processing_comment "$pr_number" "$new_round" "$max_rounds"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_classify_round_outcome: round 終了時の outcome を 1 単語で分類する純粋関数
#   入力: $1=commit_pushed ("true" | "false")
#         $2=new_streak (非負整数。加算済みの no-progress 連続カウンタ値)
#         $3=limit      (非負整数。PR_ITERATION_NO_PROGRESS_LIMIT 値)
#   出力: stdout に下記いずれか 1 単語
#           "success"     - commit 有り → 通常 finalize（needs-iteration を外す）に進む
#           "escalate"    - commit 無し かつ streak >= limit → claude-failed へ昇格
#           "no-progress" - commit 無し かつ streak < limit → needs-iteration 据え置き
#   返り値: 0 固定
#
#   設計判断 (#397 fix):
#     - commit_pushed=false の round は no-progress streak の状態に関わらず、
#       finalize 経路（needs-iteration → awaiting-design-review / ready-for-review）に
#       進ませない。streak が limit 未満なら next cycle で再 pickup されるよう
#       needs-iteration を据え置き、limit 到達時のみ escalate に倒す。
#     - 旧実装（#122 まで）は no-progress でも streak<limit なら finalize 成功扱いに
#       なっており、PR が候補プールから外れて no-progress カウンタが二度と加算されない
#       silent deadlock を起こしていた（#397）。本関数の "no-progress" 分類はその
#       deadlock を断ち切る分岐点。
#     - 純粋関数（副作用なし / グローバル参照なし）として実装し、テストで隔離検証可能。
#     - 不正値の場合（commit_pushed が "true"/"false" 以外、または非数値 streak/limit）は
#       安全側に倒して "no-progress" を返す（NFR 2.1: 判定情報が取得不能なら success に
#       倒さない）。
# ─────────────────────────────────────────────────────────────────────────────
pi_classify_round_outcome() {
  local commit_pushed="${1-}"
  local new_streak="${2-}"
  local limit="${3-}"

  # commit_pushed=true は最優先（streak は呼び出し元で 0 にリセットされている前提）
  if [ "$commit_pushed" = "true" ]; then
    echo "success"
    return 0
  fi

  # commit_pushed が "false" でない場合は安全側に no-progress 扱い
  if [ "$commit_pushed" != "false" ]; then
    echo "no-progress"
    return 0
  fi

  # streak / limit が数値で取れているときのみ escalate 判定。それ以外は no-progress に倒す
  # （NFR 2.1: 判定情報不足時は finalize=success に進ませない安全側挙動）。
  if [[ "$new_streak" =~ ^[0-9]+$ ]] && [[ "$limit" =~ ^[0-9]+$ ]] && [ "$new_streak" -ge "$limit" ]; then
    echo "escalate"
    return 0
  fi
  echo "no-progress"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_round_commit_pushed: round 開始時 HEAD と round 終了時 HEAD の SHA 比較で
#   「新規 commit が push されたか（= 進捗ありか）」を判定する純粋関数
#   入力: $1=before_sha (round 開始時の HEAD SHA)
#         $2=after_sha  (round 終了時の HEAD SHA。auto-recovery commit 後の値を含む)
#   出力: stdout に "true"（HEAD が変化 = 進捗あり）/ "false"（変化なし = 進捗なし）
#   返り値: 0 固定
#
#   設計判断 (Issue #122 Req 3.1 / 3.2 / Issue #435 Req 2):
#     - before_sha と after_sha が両方とも非空 かつ 相異なるときのみ "true"。
#     - after_sha は pi_auto_commit_and_push（auto-recovery）の後に採取されるため、
#       Developer 自身の commit と auto-recovery commit のどちらで HEAD が進んでも
#       "true" になる（Issue #435 Req 2.3 の不変条件を 1 か所に固定する）。
#     - いずれかの SHA が空（取得失敗）の場合は "false"（進捗なし＝安全側）に倒し、
#       SHA が取れないことを進捗ありと誤判定して finalize へ倒さない。
#     - 純粋関数（副作用なし / グローバル参照なし）として pi_run_iteration から呼び出し、
#       テストで隔離検証可能にする。
# ─────────────────────────────────────────────────────────────────────────────
pi_round_commit_pushed() {
  local before_sha="${1-}"
  local after_sha="${2-}"
  if [ -n "$before_sha" ] && [ -n "$after_sha" ] && [ "$before_sha" != "$after_sha" ]; then
    echo "true"
  else
    echo "false"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_next_no_progress_streak: no-progress 連続カウンタの次値を求める純粋関数
#   入力: $1=commit_pushed ("true" | "false")
#         $2=prev_streak   (非負整数。前サイクルまでの no-progress 連続カウンタ値)
#   出力: stdout に次の streak 値
#           commit_pushed=true  → "0"（進捗ありでリセット）
#           commit_pushed=false → prev_streak + 1（進捗なしで加算）
#   返り値: 0 固定
#
#   設計判断 (Issue #122 Req 3.1 / 3.2 / Issue #435 Req 2):
#     - commit_pushed が "true" のときのみ 0 にリセット。auto-recovery 経由でも
#       pi_round_commit_pushed が "true" を返すため streak は 0 にリセットされる
#       （Issue #435 Req 2.3）。
#     - prev_streak が非数値（取得失敗）の場合は 0 起点として +1 し、誤って大きな値で
#       escalate に倒さない安全側挙動とする。
# ─────────────────────────────────────────────────────────────────────────────
pi_next_no_progress_streak() {
  local commit_pushed="${1-}"
  local prev_streak="${2-}"
  if [ "$commit_pushed" = "true" ]; then
    echo "0"
    return 0
  fi
  if [[ "$prev_streak" =~ ^[0-9]+$ ]]; then
    echo "$((prev_streak + 1))"
  else
    echo "1"
  fi
  return 0
}
