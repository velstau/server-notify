#!/usr/bin/env bash
# checks.sh - 各種チェック本体
# 依存: coreutils, awk, openssl, curl, docker, systemctl (どれも標準/導入済み)

# ============================================================
# SSL 証明書の有効期限
#   SSL_TARGETS   : "host" または "host:port" (リモートを実際に TLS 接続して確認)
#   SSL_CERT_FILES: ローカルの PEM (glob 可)
# ============================================================
_ssl_eval() {
  local label="$1" enddate="$2" now exp days lv
  now=$(date +%s)
  exp=$(date -d "$enddate" +%s 2>/dev/null)
  if [[ -z "$exp" ]]; then
    item "$LV_WARN" "${label} 有効期限を解釈できません (${enddate})"
    return
  fi
  days=$(( (exp - now) / 86400 ))
  if   (( days <= SSL_CRIT_DAYS )); then lv=$LV_CRIT
  elif (( days <= SSL_WARN_DAYS )); then lv=$LV_WARN
  else lv=$LV_OK; fi
  if (( days < 0 )); then
    item "$LV_CRIT" "${label} 失効済み ($(( -days ))日経過 / $(date -d "@$exp" '+%F'))"
  else
    item "$lv" "$(printf '%-28s 残り %3d日 (%s)' "$label" "$days" "$(date -d "@$exp" '+%F')")"
  fi
}

check_ssl() {
  section "SSL証明書の期限"
  local t host port enddate pattern f found=0

  for t in "${SSL_TARGETS[@]:-}"; do
    [[ -z "$t" ]] && continue
    found=1
    host="${t%%:*}"; port="${t##*:}"
    [[ "$port" == "$t" ]] && port=443
    enddate=$(echo | timeout "$SSL_TIMEOUT" openssl s_client -servername "$host" \
                -connect "${host}:${port}" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null)
    enddate="${enddate#notAfter=}"
    if [[ -z "$enddate" ]]; then
      item "$LV_WARN" "${host}:${port} 証明書を取得できません (DNS未設定 / 443未開放 / 接続失敗)"
      continue
    fi
    _ssl_eval "${host}:${port}" "$enddate"
  done

  shopt -s nullglob
  for pattern in "${SSL_CERT_FILES[@]:-}"; do
    [[ -z "$pattern" ]] && continue
    for f in $pattern; do
      [[ -r "$f" ]] || continue
      found=1
      enddate=$(openssl x509 -noout -enddate -in "$f" 2>/dev/null)
      enddate="${enddate#notAfter=}"
      if [[ -z "$enddate" ]]; then
        item "$LV_WARN" "${f} 証明書として読めません (鍵ファイル等を glob に含めていませんか)"
        continue
      fi
      # ラベルは証明書の CN を使う (取れなければ親ディレクトリ名)
      local cn
      cn=$(openssl x509 -noout -subject -in "$f" 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p' | head -1)
      cn="${cn%"${cn##*[![:space:]]}"}"
      [[ -z "$cn" ]] && cn="$(basename "$(dirname "$f")")"
      _ssl_eval "${cn} (file)" "$enddate"
    done
  done
  shopt -u nullglob

  (( found )) || item "$LV_INFO" "チェック対象が未設定です (config.sh の SSL_TARGETS)"
}

# ============================================================
# ディスク容量 (使用率 + inode + 増加トレンドによる満杯予測)
# ============================================================
_disk_trend() {
  # $1=mount $2=used_bytes $3=avail_bytes  → 傾向を note で出力
  local mnt="$1" used="$2" avail="$3"
  local hist="$STATE_DIR/disk_history.tsv" now old_epoch old_used span_days per_day eta
  now=$(date +%s)

  if [[ -f "$hist" ]]; then
    read -r old_epoch old_used < <(awk -F'\t' -v m="$mnt" -v now="$now" -v win="$((DISK_TREND_DAYS*86400))" '
      $2==m && (now-$1) >= 21600 && (now-$1) <= win { print $1"\t"$3; exit }' "$hist")
  fi

  printf '%s\t%s\t%s\n' "$now" "$mnt" "$used" >> "$hist"
  # 履歴が肥大しないよう末尾のみ保持
  if [[ $(wc -l < "$hist" 2>/dev/null || echo 0) -gt 2000 ]]; then
    tail -n 1000 "$hist" > "${hist}.tmp" && mv "${hist}.tmp" "$hist"
  fi

  [[ -z "${old_epoch:-}" || -z "${old_used:-}" ]] && return 0
  span_days=$(fdiv $(( now - old_epoch )) 86400 3)
  per_day=$(awk -v d="$(( used - old_used ))" -v s="$span_days" 'BEGIN{ printf "%d", (s>0 ? d/s : 0) }')

  if (( per_day > 0 )); then
    eta=$(awk -v a="$avail" -v p="$per_day" 'BEGIN{ printf "%d", a/p }')
    note "増加 +$(human_bytes "$per_day")/日 (過去${span_days}日) → 満杯まで約 ${eta}日"
    if (( eta <= DISK_ETA_CRIT_DAYS )); then
      item "$LV_CRIT" "${mnt} このペースだと約 ${eta}日で枯渇します"
    elif (( eta <= DISK_ETA_WARN_DAYS )); then
      item "$LV_WARN" "${mnt} このペースだと約 ${eta}日で枯渇します"
    fi
  elif (( per_day < 0 )); then
    note "増加 -$(human_bytes $(( -per_day )))/日 (過去${span_days}日・減少傾向)"
  fi
}

check_disk() {
  section "ディスク容量"
  local dfout size used avail usep mnt lv

  if (( ${#DISK_MOUNTS[@]} )); then
    dfout=$(df -P -B1 "${DISK_MOUNTS[@]}" 2>/dev/null | tail -n +2)
  else
    dfout=$(df -P -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)
  fi

  while read -r _ size used avail usep mnt; do
    [[ -z "${mnt:-}" ]] && continue
    usep="${usep%\%}"
    if   (( usep >= DISK_CRIT_PCT )); then lv=$LV_CRIT
    elif (( usep >= DISK_WARN_PCT )); then lv=$LV_WARN
    else lv=$LV_OK; fi
    item "$lv" "$(printf '%-14s %3d%%  使用 %s / %s  (空き %s)' \
      "$mnt" "$usep" "$(human_bytes "$used")" "$(human_bytes "$size")" "$(human_bytes "$avail")")"
    (( DISK_TREND )) && _disk_trend "$mnt" "$used" "$avail"
  done <<< "$dfout"

  # inode
  local iout ipct
  if (( ${#DISK_MOUNTS[@]} )); then
    iout=$(df -P -i "${DISK_MOUNTS[@]}" 2>/dev/null | tail -n +2)
  else
    iout=$(df -P -i -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)
  fi
  while read -r _ size used avail usep mnt; do
    [[ -z "${mnt:-}" ]] && continue
    ipct="${usep%\%}"
    [[ "$ipct" =~ ^[0-9]+$ ]] || continue
    if   (( ipct >= INODE_CRIT_PCT )); then item "$LV_CRIT" "${mnt} inode 使用率 ${ipct}%"
    elif (( ipct >= INODE_WARN_PCT )); then item "$LV_WARN" "${mnt} inode 使用率 ${ipct}%"
    fi
  done <<< "$iout"
}

# ============================================================
# ログフォルダの容量
# ============================================================
check_logdir() {
  section "ログ容量"
  local d total lv children sz path

  for d in "${LOG_DIRS[@]:-}"; do
    [[ -z "$d" ]] && continue
    if [[ ! -d "$d" ]]; then
      item "$LV_INFO" "${d} (存在しません)"
      continue
    fi
    total=$(du -s --block-size=1 "$d" 2>/dev/null | awk '{print $1}')
    total="${total:-0}"
    if   (( total >= LOGDIR_CRIT_MB * 1048576 )); then lv=$LV_CRIT
    elif (( total >= LOGDIR_WARN_MB * 1048576 )); then lv=$LV_WARN
    else lv=$LV_OK; fi
    item "$lv" "$(printf '%s  合計 %s' "$d" "$(human_bytes "$total")")"

    children=$(du -s --block-size=1 "$d"/* 2>/dev/null | sort -rn | head -n "$LOGDIR_TOP_N")
    while read -r sz path; do
      [[ -z "${path:-}" ]] && continue
      (( sz < LOGDIR_CHILD_MIN_MB * 1048576 )) && continue
      note "$(printf '%8s  %s' "$(human_bytes "$sz")" "$path")"
      if [[ "$path" == */journal ]] && (( sz > 500 * 1048576 )); then
        note "          → 削減: sudo journalctl --vacuum-size=500M"
      fi
    done <<< "$children"

    # 単体で肥大したログファイル
    local big
    big=$(find "$d" -maxdepth "$LOGFILE_FIND_DEPTH" -type f -printf '%b\t%p\n' 2>/dev/null \
            | awk -F'\t' -v min="$(( LOGFILE_WARN_MB * 2048 ))" '$1 >= min { printf "%d\t%s\n", $1*512, $2 }' \
            | sort -rn | head -n 3)
    while IFS=$'\t' read -r sz path; do
      [[ -z "${path:-}" ]] && continue
      item "$LV_WARN" "肥大ログ $(human_bytes "$sz")  ${path}"
    done <<< "$big"
  done
}

# ============================================================
# Docker (削除可能容量 + コンテナ状態)
# ============================================================
check_docker() {
  section "Docker"
  if ! command -v docker >/dev/null 2>&1; then
    item "$LV_INFO" "docker コマンドがありません"
    return
  fi
  if ! docker info >/dev/null 2>&1; then
    item "$LV_CRIT" "docker デーモンに接続できません"
    return
  fi

  local dfout type total active size recl reclb sum=0 lv
  dfout=$(docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)
  while IFS='|' read -r type total active size recl; do
    [[ -z "${type:-}" ]] && continue
    reclb=$(to_bytes "$recl")
    sum=$(( sum + reclb ))
    note "$(printf '%-14s 全%3s件(使用中%3s)  使用 %-9s 削除可 %s' \
      "$type" "$total" "$active" "$size" "$(human_bytes "$reclb")")"
  done <<< "$dfout"

  if   (( sum >= DOCKER_RECLAIM_CRIT_MB * 1048576 )); then lv=$LV_CRIT
  elif (( sum >= DOCKER_RECLAIM_WARN_MB * 1048576 )); then lv=$LV_WARN
  else lv=$LV_OK; fi
  item "$lv" "削除できそうな容量 合計 $(human_bytes "$sum")"

  local exited dangling volumes
  exited=$(docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | wc -l)
  dangling=$(docker images -f dangling=true -q 2>/dev/null | wc -l)
  volumes=$(docker volume ls -qf dangling=true 2>/dev/null | wc -l)
  note "停止済みコンテナ ${exited}件 / 未参照イメージ ${dangling}件 / 未使用ボリューム ${volumes}件"
  if (( sum >= DOCKER_RECLAIM_WARN_MB * 1048576 )); then
    note "回収例: docker system prune -f  /  docker builder prune -f  /  docker image prune -a"
    note "（ボリュームは docker volume prune で消えるため中身を確認してから）"
  fi

  # コンテナの異常
  local name st health policy rc ign skip
  while read -r name; do
    [[ -z "${name:-}" ]] && continue
    skip=0
    for ign in "${DOCKER_IGNORE_CONTAINERS[@]:-}"; do
      # shellcheck disable=SC2053  # 右辺は glob として評価させる
      [[ -n "$ign" && "$name" == $ign ]] && skip=1 && break
    done
    (( skip )) && continue
    read -r st health policy rc < <(docker inspect \
      -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{if .HostConfig.RestartPolicy.Name}}{{.HostConfig.RestartPolicy.Name}}{{else}}no{{end}} {{.RestartCount}}' \
      "$name" 2>/dev/null)
    [[ -z "${st:-}" ]] && continue
    if [[ "$st" != "running" && "$policy" =~ ^(always|unless-stopped)$ ]]; then
      item "$LV_CRIT" "コンテナ停止中: ${name} (status=${st}, restart=${policy})"
    elif [[ "$health" == "unhealthy" && "$st" == "running" ]]; then
      item "$LV_WARN" "ヘルスチェック異常: ${name}"
    elif (( rc >= DOCKER_RESTART_WARN )); then
      item "$LV_WARN" "再起動が多い: ${name} (${rc}回)"
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
}

# ============================================================
# メモリ / スワップ
# ============================================================
check_memory() {
  section "メモリ"
  local mt ma st su avail_pct swap_pct
  read -r mt ma < <(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{print t, a}' /proc/meminfo)
  read -r st su < <(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print t, t-f}' /proc/meminfo)

  avail_pct=$(pct "$ma" "$mt")
  if   (( avail_pct <= MEM_CRIT_AVAIL_PCT )); then
    item "$LV_CRIT" "利用可能メモリ ${avail_pct}% ($(human_bytes $((ma*1024))) / $(human_bytes $((mt*1024))))"
  elif (( avail_pct <= MEM_WARN_AVAIL_PCT )); then
    item "$LV_WARN" "利用可能メモリ ${avail_pct}% ($(human_bytes $((ma*1024))) / $(human_bytes $((mt*1024))))"
  else
    item "$LV_OK" "利用可能メモリ ${avail_pct}% ($(human_bytes $((ma*1024))) / $(human_bytes $((mt*1024))))"
  fi

  if (( st > 0 )); then
    swap_pct=$(pct "$su" "$st")
    if (( swap_pct >= SWAP_WARN_PCT )); then
      item "$LV_WARN" "スワップ使用率 ${swap_pct}% ($(human_bytes $((su*1024))) / $(human_bytes $((st*1024))))"
      local pname pswap
      while read -r pswap pname; do
        [[ -z "${pname:-}" ]] && continue
        note "$(printf '%8s  %s' "$(human_bytes $((pswap*1024)))" "$pname")"
      done <<< "$(awk '/^Name:/{n=$2}/^VmSwap:/{if($2>51200) print $2"\t"n}' /proc/[0-9]*/status 2>/dev/null | sort -rn | head -n 3)"
    else
      item "$LV_OK" "スワップ使用率 ${swap_pct}%"
    fi
  fi
}

# ============================================================
# 負荷 / 稼働時間
# ============================================================
check_load() {
  section "CPU負荷"
  local l1 l5 l15 cores ratio lv up_days
  read -r l1 l5 l15 _ < /proc/loadavg
  cores=$(nproc 2>/dev/null || echo 1)
  ratio=$(fdiv "$l5" "$cores" 2)
  if   ge "$ratio" "$LOAD_CRIT_RATIO"; then lv=$LV_CRIT
  elif ge "$ratio" "$LOAD_WARN_RATIO"; then lv=$LV_WARN
  else lv=$LV_OK; fi
  item "$lv" "load ${l1} / ${l5} / ${l15}  (${cores}コア, 5分平均でコアあたり ${ratio})"
  up_days=$(awk '{printf "%d", $1/86400}' /proc/uptime)
  note "稼働 ${up_days}日"
}

# ============================================================
# Web サイトの死活 (HTTP)
# ============================================================
check_http() {
  section "Webサイト死活"
  local spec url expect res code tsec lv
  local found=0
  for spec in "${HTTP_TARGETS[@]:-}"; do
    [[ -z "$spec" ]] && continue
    found=1
    url="${spec%%|*}"; expect="${spec##*|}"
    [[ "$expect" == "$spec" ]] && expect=200
    res=$(curl -sS -o /dev/null --max-time "$HTTP_TIMEOUT" \
            -w '%{http_code} %{time_total}' "$url" 2>/dev/null)
    code="${res%% *}"; tsec="${res##* }"
    tsec=$(awk -v t="${tsec:-0}" 'BEGIN{ printf "%.2f", t }')
    if [[ -z "$code" || "$code" == "000" ]]; then
      item "$LV_CRIT" "${url} 接続失敗"
    elif [[ "$code" != "$expect" ]]; then
      item "$LV_CRIT" "${url} HTTP ${code} (期待 ${expect})"
    elif ge "$tsec" "$HTTP_SLOW_SEC"; then
      item "$LV_WARN" "${url} 応答が遅い ${tsec}s (HTTP ${code})"
    else
      item "$LV_OK" "$(printf '%-44s HTTP %s  %ss' "$url" "$code" "$tsec")"
    fi
  done
  (( found )) || item "$LV_INFO" "チェック対象が未設定です (config.sh の HTTP_TARGETS)"
}

# ============================================================
# 更新 / 再起動要求
# ============================================================
check_updates() {
  section "OS更新"
  local total sec pkgs up_days

  if command -v apt-get >/dev/null 2>&1; then
    local inst
    inst=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -E '^Inst ')
    total=$(printf '%s' "$inst" | grep -c '^Inst ' || true)
    sec=$(printf '%s' "$inst" | grep -c -- '-security' || true)
    if   (( sec > 0 ));  then item "$LV_WARN" "未適用の更新 ${total}件 (うちセキュリティ ${sec}件)"
    elif (( total > UPDATE_WARN_COUNT )); then item "$LV_WARN" "未適用の更新 ${total}件"
    else item "$LV_OK" "未適用の更新 ${total}件"
    fi
  fi

  if [[ -f /var/run/reboot-required ]]; then
    pkgs=$(head -c 200 /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')
    item "$LV_WARN" "再起動が必要です ($(date -r /var/run/reboot-required '+%F') 以降)"
    [[ -n "$pkgs" ]] && note "対象: ${pkgs}"
  fi

  up_days=$(awk '{printf "%d", $1/86400}' /proc/uptime)
  if (( up_days >= UPTIME_WARN_DAYS )); then
    item "$LV_WARN" "${up_days}日間 未再起動 (カーネル更新が反映されていない可能性)"
  fi
}

# ============================================================
# systemd の failed ユニット
# ============================================================
check_systemd() {
  section "systemd"
  local unit rest ign skip
  local failed
  failed=$(systemctl --failed --no-legend --no-pager 2>/dev/null | sed 's/^[●*] *//')
  if [[ -z "$failed" ]]; then
    item "$LV_OK" "failed ユニットなし"
    return
  fi
  while read -r unit rest; do
    [[ -z "${unit:-}" ]] && continue
    skip=0
    for ign in "${SYSTEMD_IGNORE_UNITS[@]:-}"; do
      # shellcheck disable=SC2053  # 右辺は glob として評価させる
      [[ -n "$ign" && "$unit" == $ign ]] && skip=1 && break
    done
    (( skip )) && continue
    item "$LV_WARN" "failed: ${unit}"
  done <<< "$failed"
}

# ============================================================
# バックアップ / 定期ジョブの鮮度
#   BACKUP_PATHS: "パス" または "パス|許容時間(h)"
# ============================================================
check_backup() {
  section "バックアップ鮮度"
  local spec path maxh newest age_h found=0
  for spec in "${BACKUP_PATHS[@]:-}"; do
    [[ -z "$spec" ]] && continue
    found=1
    path="${spec%%|*}"; maxh="${spec##*|}"
    [[ "$maxh" == "$spec" ]] && maxh="$BACKUP_MAX_AGE_HOURS"
    if [[ ! -e "$path" ]]; then
      item "$LV_CRIT" "${path} が存在しません"
      continue
    fi
    if [[ -d "$path" ]]; then
      newest=$(find "$path" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
      newest="${newest%%.*}"
    else
      newest=$(stat -c %Y "$path" 2>/dev/null)
    fi
    if [[ -z "${newest:-}" ]]; then
      item "$LV_WARN" "${path} 更新時刻を取得できません"
      continue
    fi
    age_h=$(( ( $(date +%s) - newest ) / 3600 ))
    if (( age_h > maxh )); then
      item "$LV_CRIT" "${path} が ${age_h}時間 更新されていません (許容 ${maxh}h)"
    else
      item "$LV_OK" "$(printf '%-44s %d時間前に更新' "$path" "$age_h")"
    fi
  done
  (( found )) || item "$LV_INFO" "チェック対象が未設定です (config.sh の BACKUP_PATHS)"
}
