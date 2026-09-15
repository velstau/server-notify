#!/usr/bin/env bash
#
# server-notify.sh - サーバー状態を Discord / Slack / Google Chat に通知する
#
#   追加ライブラリ不要 (bash + coreutils + openssl + curl + docker のみ)
#   使い方:  ./server-notify.sh --dry-run     # 送信せず標準出力に表示
#            ./server-notify.sh               # config.sh の宛先へ送信
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
STATE_DIR="${SCRIPT_DIR}/state"

# ============================================================
# 既定値 (config.sh で上書きする)
# ============================================================
DISCORD_WEBHOOK_URLS=()
SLACK_WEBHOOK_URLS=()
GOOGLE_CHAT_WEBHOOK_URLS=()
NOTIFY_USERNAME="server-notify"
NOTIFY_TIMEOUT=15
NOTIFY_RETRY=3

ENABLED_CHECKS=(ssl disk logdir docker memory load http updates systemd backup)
NOTIFY_LEVEL="ok"            # ok=毎回送る / warn=WARN以上 / crit=CRITのみ
REPORT_MODE="full"           # full=全項目 / issues=WARN以上の節のみ
SUPPRESS_REPEAT_MIN=0        # 同レベルの連投を抑制する分数 (0=抑制しない)

SSL_TARGETS=()
SSL_CERT_FILES=()
SSL_WARN_DAYS=21
SSL_CRIT_DAYS=7
SSL_TIMEOUT=10

DISK_MOUNTS=()
DISK_WARN_PCT=80
DISK_CRIT_PCT=90
INODE_WARN_PCT=80
INODE_CRIT_PCT=90
DISK_TREND=1
DISK_TREND_DAYS=14
DISK_ETA_WARN_DAYS=60
DISK_ETA_CRIT_DAYS=14

LOG_DIRS=(/var/log)
LOGDIR_WARN_MB=2048
LOGDIR_CRIT_MB=8192
LOGDIR_TOP_N=5
LOGDIR_CHILD_MIN_MB=50
LOGFILE_WARN_MB=500
LOGFILE_FIND_DEPTH=3

DOCKER_RECLAIM_WARN_MB=10240
DOCKER_RECLAIM_CRIT_MB=40960
DOCKER_RESTART_WARN=5
DOCKER_IGNORE_CONTAINERS=()

MEM_WARN_AVAIL_PCT=15
MEM_CRIT_AVAIL_PCT=7
SWAP_WARN_PCT=80

LOAD_WARN_RATIO=1.5
LOAD_CRIT_RATIO=3.0

HTTP_TARGETS=()
HTTP_TIMEOUT=10
HTTP_SLOW_SEC=3.0

UPDATE_WARN_COUNT=50
UPTIME_WARN_DAYS=180

SYSTEMD_IGNORE_UNITS=()

BACKUP_PATHS=()
BACKUP_MAX_AGE_HOURS=26

# ============================================================
# 引数
# ============================================================
DRY_RUN=0; QUIET=0; VERBOSE=0; TEST_MODE=0; ONLY=""; LEVEL_OVERRIDE=""; MODE_OVERRIDE=""

usage() {
  cat <<'USAGE'
使い方: server-notify.sh [オプション]

  -c, --config FILE   設定ファイル (既定: スクリプトと同じ場所の config.sh)
  -n, --dry-run       送信せず標準出力に表示するだけ
  -q, --quiet         標準出力に出さない (cron 向け)
  -v, --verbose       送信結果などを stderr に出す
      --only LIST     指定チェックのみ実行 (カンマ区切り)
                      ssl,disk,logdir,docker,memory,load,http,updates,systemd,backup
      --level LEVEL   送信閾値を上書き (ok|warn|crit)
      --mode MODE     full|issues (issues は WARN 以上の節だけ本文に載せる)
      --test          疎通確認用のテストメッセージを全宛先へ送る
  -h, --help          このヘルプ

終了コード: 0=OK / 1=WARN / 2=CRIT / 3=設定・送信エラー
USAGE
}

while (( $# )); do
  case "$1" in
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --level) LEVEL_OVERRIDE="$2"; shift 2 ;;
    --mode) MODE_OVERRIDE="$2"; shift 2 ;;
    --test) TEST_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; usage >&2; exit 3 ;;
  esac
done

# ============================================================
# 読み込み
# ============================================================
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"   || { echo "lib/core.sh を読めません" >&2; exit 3; }
source "${SCRIPT_DIR}/lib/notify.sh" || { echo "lib/notify.sh を読めません" >&2; exit 3; }
source "${SCRIPT_DIR}/lib/checks.sh" || { echo "lib/checks.sh を読めません" >&2; exit 3; }

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE" || { log_err "設定ファイルの読み込みに失敗: $CONFIG_FILE"; exit 3; }
else
  log_err "設定ファイルがありません: $CONFIG_FILE (config.sh.example をコピーしてください)"
  (( DRY_RUN )) || exit 3
fi

[[ -n "$LEVEL_OVERRIDE" ]] && NOTIFY_LEVEL="$LEVEL_OVERRIDE"
[[ -n "$MODE_OVERRIDE"  ]] && REPORT_MODE="$MODE_OVERRIDE"
mkdir -p "$STATE_DIR" 2>/dev/null

HOSTNAME_S="$(hostname -s 2>/dev/null || hostname)"
NOW_STR="$(date '+%Y-%m-%d %H:%M')"
FOOTER="${HOSTNAME_S} ・ ${NOW_STR} ・ server-notify.sh"

# ============================================================
# テストモード
# ============================================================
if (( TEST_MODE )); then
  dispatch "[TEST] ${HOSTNAME_S} 疎通確認" \
    "server-notify.sh からのテスト送信です。"$'\n'"改行・日本語・記号 \" \\ { } が正しく表示されていれば OK です。" \
    0 "$FOOTER"
  rc=$?
  if (( rc == 0 )); then echo "テスト送信に成功しました。"; exit 0; fi
  echo "テスト送信に失敗しました。" >&2; exit 3
fi

# ============================================================
# 多重起動防止
# ============================================================
LOCK_FILE="${STATE_DIR}/.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log_err "既に実行中のため終了します"
  exit 0
fi

# ============================================================
# チェック実行
# ============================================================
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a ENABLED_CHECKS <<< "$ONLY"
fi

for c in "${ENABLED_CHECKS[@]}"; do
  c="${c// /}"
  [[ -z "$c" ]] && continue
  if declare -F "check_${c}" >/dev/null; then
    "check_${c}" || log_err "check_${c} が異常終了しました"
  else
    log_err "不明なチェック: ${c}"
  fi
done
report_finalize

STATUS="$(level_name "$OVERALL")"
TITLE="[${STATUS}] ${HOSTNAME_S} サーバー状態レポート"

(( QUIET )) || { echo "${TITLE}"; echo; echo "${BODY}"; echo; echo "${FOOTER}"; }

# ============================================================
# 送信判定
# ============================================================
if (( DRY_RUN )); then
  exit "$OVERALL"
fi

THRESHOLD="$(level_value "$NOTIFY_LEVEL")"
LAST_FILE="${STATE_DIR}/last_notify"
LAST_LEVEL=0; LAST_SENT=0
[[ -f "$LAST_FILE" ]] && read -r LAST_LEVEL LAST_SENT < "$LAST_FILE"
LAST_LEVEL="${LAST_LEVEL:-0}"; LAST_SENT="${LAST_SENT:-0}"

SHOULD_SEND=0
RECOVERED=0
if (( OVERALL >= THRESHOLD )); then
  SHOULD_SEND=1
elif (( LAST_LEVEL > 0 && OVERALL == 0 )); then
  SHOULD_SEND=1; RECOVERED=1      # 復旧は閾値に関係なく1回だけ通知
fi

NOW_EPOCH="$(date +%s)"
if (( SHOULD_SEND && ! RECOVERED && SUPPRESS_REPEAT_MIN > 0 )); then
  if (( OVERALL <= LAST_LEVEL && NOW_EPOCH - LAST_SENT < SUPPRESS_REPEAT_MIN * 60 )); then
    SHOULD_SEND=0
    (( VERBOSE )) && log_err "連投抑制中のため送信しません (前回送信から $(( (NOW_EPOCH-LAST_SENT)/60 ))分)"
  fi
fi

rc=0
if (( SHOULD_SEND )); then
  (( RECOVERED )) && TITLE="[復旧] ${HOSTNAME_S} 正常に戻りました"
  dispatch "$TITLE" "$BODY" "$OVERALL" "$FOOTER"
  rc=$?
  (( rc == 0 )) && LAST_SENT="$NOW_EPOCH"
fi
printf '%s %s\n' "$OVERALL" "$LAST_SENT" > "$LAST_FILE"

(( rc != 0 )) && exit 3
exit "$OVERALL"
