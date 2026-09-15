#!/usr/bin/env bash
# notify.sh - Discord / Slack / Google Chat への送信
# 依存: curl のみ (jq 不要。JSON は core.sh の json_escape で手組み)

# レベル別の色
_color_hex() {
  case "$1" in
    2) printf '#E74C3C' ;;   # 赤
    1) printf '#F1C40F' ;;   # 黄
    *) printf '#2ECC71' ;;   # 緑
  esac
}
_color_int() {
  case "$1" in
    2) printf '15158332' ;;
    1) printf '15844367' ;;
    *) printf '3066993'  ;;
  esac
}

# _post <url> <json> <宛先ラベル>
_post() {
  local url="$1" payload="$2" label="$3"
  local attempt=0 code body
  while (( attempt < NOTIFY_RETRY )); do
    attempt=$((attempt+1))
    body=$(curl -sS -X POST -H 'Content-Type: application/json; charset=utf-8' \
             --max-time "$NOTIFY_TIMEOUT" -w '\n%{http_code}' \
             --data-binary "$payload" "$url" 2>&1)
    code="${body##*$'\n'}"
    if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
      (( VERBOSE )) && log_err "送信成功: ${label} (HTTP ${code})"
      return 0
    fi
    log_err "送信失敗: ${label} (HTTP ${code:-?}) 試行 ${attempt}/${NOTIFY_RETRY}: ${body%$'\n'*}"
    (( attempt < NOTIFY_RETRY )) && sleep $(( attempt * 3 ))
  done
  return 1
}

# send_discord <url> <title> <body> <level> <footer>
send_discord() {
  local url="$1" title="$2" body="$3" lv="$4" footer="$5"
  body=$(truncate_text "$body" 4000)
  local payload
  payload=$(printf '{"username":"%s","embeds":[{"title":"%s","description":"%s","color":%s,"footer":{"text":"%s"}}]}' \
    "$(json_escape "$NOTIFY_USERNAME")" \
    "$(json_escape "$title")" \
    "$(json_escape "$body")" \
    "$(_color_int "$lv")" \
    "$(json_escape "$footer")")
  _post "$url" "$payload" "Discord"
}

# send_slack <url> <title> <body> <level> <footer>
send_slack() {
  local url="$1" title="$2" body="$3" lv="$4" footer="$5"
  body=$(truncate_text "$body" 2900)
  local payload
  payload=$(printf '{"text":"%s","attachments":[{"color":"%s","text":"%s","footer":"%s","ts":%s}]}' \
    "$(json_escape "$title")" \
    "$(_color_hex "$lv")" \
    "$(json_escape "$body")" \
    "$(json_escape "$footer")" \
    "$(date +%s)")
  _post "$url" "$payload" "Slack"
}

# send_googlechat <url> <title> <body> <level> <footer>
send_googlechat() {
  local url="$1" title="$2" body="$3" lv="$4" footer="$5"
  local text
  text=$(truncate_text "${title}"$'\n'"${body}"$'\n'"${footer}" 3900)
  local payload
  payload=$(printf '{"text":"%s"}' "$(json_escape "$text")")
  _post "$url" "$payload" "Google Chat"
}

# dispatch <title> <body> <level> <footer>
# config で設定された全ての宛先へ送る (Discord+GoogleChat のような複合も可)
dispatch() {
  local title="$1" body="$2" lv="$3" footer="$4"
  local url rc=0 sent=0

  for url in "${DISCORD_WEBHOOK_URLS[@]:-}"; do
    [[ -z "$url" ]] && continue
    send_discord "$url" "$title" "$body" "$lv" "$footer" || rc=1
    sent=$((sent+1))
  done
  for url in "${SLACK_WEBHOOK_URLS[@]:-}"; do
    [[ -z "$url" ]] && continue
    send_slack "$url" "$title" "$body" "$lv" "$footer" || rc=1
    sent=$((sent+1))
  done
  for url in "${GOOGLE_CHAT_WEBHOOK_URLS[@]:-}"; do
    [[ -z "$url" ]] && continue
    send_googlechat "$url" "$title" "$body" "$lv" "$footer" || rc=1
    sent=$((sent+1))
  done

  if (( sent == 0 )); then
    log_err "宛先が1つも設定されていません (config.sh の *_WEBHOOK_URLS を確認)"
    return 3
  fi
  return $rc
}
