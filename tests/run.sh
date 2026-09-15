#!/usr/bin/env bash
#
# tests/run.sh - 外部サービスへ送信せずに動作を検証する
#   ・3 サービス分の JSON ペイロードが壊れていないか
#   ・docker が無い環境でもチェックが完走するか
#   ・終了コードと --mode / --only の挙動
#
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------
echo "1) 構文チェック"
for f in server-notify.sh lib/core.sh lib/notify.sh lib/checks.sh config.sh.example; do
  if bash -n "$f" 2>/dev/null; then ok "$f"; else fail "$f"; fi
done

# ------------------------------------------------------------
echo "2) JSON ペイロードの組み立て"
# 送信はせず、_post を差し替えてペイロードだけ取り出す
cat > "$TMP/payload.sh" <<'INNER'
set -uo pipefail
REPORT_MODE=full; VERBOSE=0; NOTIFY_TIMEOUT=5; NOTIFY_RETRY=1
NOTIFY_USERNAME='server "notify" \test'
source ./lib/core.sh
source ./lib/notify.sh
_post() { printf '%s' "$2" > "${OUT}/$(echo "$3" | tr -d ' ').json"; return 0; }
BODY=$'■ テスト\n  ✅ ダブル"クォート" バックスラッシュ \\ 中括弧 {}\n  🚨 タブ\tと 日本語 ＆ <>&'
send_discord    x 'タイトル"付き"' "$BODY" 2 'footer'
send_slack      x 'タイトル"付き"' "$BODY" 1 'footer'
send_googlechat x 'タイトル"付き"' "$BODY" 0 'footer'
INNER
OUT="$TMP" bash "$TMP/payload.sh"

for svc in Discord Slack GoogleChat; do
  f="$TMP/${svc}.json"
  if [[ ! -s "$f" ]]; then fail "${svc}: ペイロードが生成されていない"; continue; fi
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
      ok "${svc}: 妥当な JSON"
    else
      fail "${svc}: JSON が壊れている"
    fi
  else
    ok "${svc}: 生成された（python3 が無いため構文検証はスキップ）"
  fi
done

# 本文がエスケープを経て元に戻るか
if command -v python3 >/dev/null 2>&1; then
  if python3 - "$TMP/Discord.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
body = d["embeds"][0]["description"]
assert 'ダブル"クォート"' in body, body
assert "バックスラッシュ \\ " in body, body
assert "\t" in body, body
assert d["embeds"][0]["color"] == 15158332
PY
  then ok "本文がエスケープ往復で一致する"; else fail "本文がエスケープ往復で壊れる"; fi
fi

# ------------------------------------------------------------
echo "3) チェックの実行（docker 非依存のものだけ）"
cat > "$TMP/config.sh" <<'INNER'
ENABLED_CHECKS=(disk logdir memory load)
LOG_DIRS=(/var/log)
DISK_MOUNTS=()
INNER

out="$("./server-notify.sh" --dry-run -c "$TMP/config.sh" 2>&1)"; rc=$?
if (( rc >= 0 && rc <= 2 )); then ok "終了コード ${rc}（0/1/2 のいずれか）"; else fail "終了コード ${rc}"; fi
for want in "■ ディスク容量" "■ ログ容量" "■ メモリ" "■ CPU負荷"; do
  if grep -qF "$want" <<< "$out"; then ok "節あり: ${want}"; else fail "節なし: ${want}"; fi
done

# --only は指定したチェックだけを実行する
out="$("./server-notify.sh" --dry-run -c "$TMP/config.sh" --only load 2>&1)"
if grep -qF "■ CPU負荷" <<< "$out" && ! grep -qF "■ メモリ" <<< "$out"; then
  ok "--only が効いている"
else
  fail "--only が効いていない"
fi

# 宛先未設定で送信しようとしたら 3 を返す
"./server-notify.sh" -c "$TMP/config.sh" --only load -q >/dev/null 2>&1; rc=$?
if (( rc == 3 )); then ok "宛先未設定なら終了コード 3"; else fail "宛先未設定で終了コード ${rc}"; fi

# ------------------------------------------------------------
echo
if (( FAIL )); then echo "テスト失敗"; exit 1; fi
echo "すべて成功"
