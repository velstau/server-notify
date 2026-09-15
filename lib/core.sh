#!/usr/bin/env bash
# core.sh - レポート組み立て / レベル管理 / 各種ユーティリティ
# 依存: bash 4+, awk, date  (追加ライブラリなし)

# shellcheck disable=SC2034  # LV_* は checks.sh から参照する
LV_INFO=-1; LV_OK=0; LV_WARN=1; LV_CRIT=2

OVERALL=0          # 全体の最大レベル
BODY=""            # 確定したレポート本文
_SEC_NAME=""       # 組み立て中のセクション名
_SEC_BUF=""        # 組み立て中のセクション本文
_SEC_LEVEL=0       # 組み立て中のセクションの最大レベル
_SEC_OPEN=0

_icon() {
  case "$1" in
    "$LV_CRIT") printf '🚨' ;;
    "$LV_WARN") printf '⚠️' ;;
    "$LV_OK")   printf '✅' ;;
    *)          printf 'ℹ️' ;;
  esac
}

level_name() {
  case "$1" in
    2) printf 'CRIT' ;;
    1) printf 'WARN' ;;
    *) printf 'OK'   ;;
  esac
}

level_value() {
  case "${1,,}" in
    crit|critical|2) printf '2' ;;
    warn|warning|1)  printf '1' ;;
    ok|info|always|0) printf '0' ;;
    *) printf '1' ;;
  esac
}

# section <表示名>
section() {
  _flush_section
  _SEC_NAME="$1"; _SEC_BUF=""; _SEC_LEVEL=0; _SEC_OPEN=1
}

# item <level> <本文>   レベル付きの1行
item() {
  local lv="$1"; shift
  _SEC_BUF+="  $(_icon "$lv") $*"$'\n'
  (( lv > _SEC_LEVEL )) && _SEC_LEVEL=$lv
  (( lv > OVERALL ))    && OVERALL=$lv
  return 0
}

# note <本文>   アイコン無しの補足行
note() { _SEC_BUF+="     $*"$'\n'; }

_flush_section() {
  (( _SEC_OPEN )) || return 0
  if [[ "$REPORT_MODE" == "full" || $_SEC_LEVEL -gt 0 ]]; then
    BODY+="■ ${_SEC_NAME}"$'\n'"${_SEC_BUF}"$'\n'
  fi
  _SEC_OPEN=0
}

report_finalize() {
  _flush_section
  BODY="${BODY%$'\n'}"
  [[ -z "$BODY" ]] && BODY="（報告対象の問題はありません）"
  return 0
}

# --- 数値 / 書式 ---

# human_bytes <bytes>
human_bytes() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB PB", u, " ")
    i=1; while (b>=1024 && i<6) { b/=1024; i++ }
    if (i==1) printf "%dB", b; else printf "%.1f%s", b, u[i]
  }'
}

# to_bytes <"10.96GB (62%)"> [base]   docker の表記などをバイトに戻す (既定 base=1000)
to_bytes() {
  awk -v s="$1" -v base="${2:-1000}" 'BEGIN{
    if (!match(s, /[0-9.]+/)) { print 0; exit }
    n = substr(s, RSTART, RLENGTH)
    r = substr(s, RSTART+RLENGTH); sub(/^ +/, "", r); u = toupper(r)
    m = 1
    if      (u ~ /^K/) m = base
    else if (u ~ /^M/) m = base^2
    else if (u ~ /^G/) m = base^3
    else if (u ~ /^T/) m = base^4
    printf "%d", n*m
  }'
}

# pct <分子> <分母>   整数パーセント
pct() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ printf "%d", (b>0 ? a*100/b : 0) }'; }

# fdiv <a> <b> <桁>
fdiv() { awk -v a="${1:-0}" -v b="${2:-0}" -v d="${3:-1}" 'BEGIN{ printf "%.*f", d, (b!=0 ? a/b : 0) }'; }

# ge <a> <b>   小数対応の a >= b
ge() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ exit !(a >= b) }'; }

# --- JSON ---

# json_escape <文字列>   " \ 改行 タブ をエスケープ (UTF-8 はそのまま通す)
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# truncate_text <文字列> <最大文字数>
truncate_text() {
  local s="$1" max="$2"
  if (( ${#s} > max )); then
    printf '%s' "${s:0:$((max-20))}"$'\n'"…(長すぎるため省略)"
  else
    printf '%s' "$s"
  fi
}

log_err() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
