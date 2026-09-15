# server-notify.sh

サーバーの状態を点検して **Discord / Slack / Google Chat** へ通知するシェルスクリプト。

- **追加ライブラリ・ランタイム不要** — bash + coreutils + `openssl` + `curl` + `docker` だけで動く（Python も jq も使わない）
- 通知先は**複数・複合指定が可能**（Discord のみ / Google Chat のみ / Discord + Google Chat など）
- cron に 1 行足すだけで日次サマリ・障害アラートの両方を運用できる

```
notify_shell/
├── server-notify.sh     # 実行するのはこれだけ
├── config.sh.example    # 設定テンプレート
├── config.sh            # 実設定（Webhook URL を書く。Git に入れない）
├── lib/
│   ├── core.sh          # レポート組み立て・JSON エスケープ
│   ├── notify.sh        # Discord / Slack / Google Chat 送信
│   └── checks.sh        # 各チェック本体
└── state/               # 前回結果・ディスク使用量の履歴（自動生成）
```

## セットアップ

```bash
cp config.sh.example config.sh
chmod 600 config.sh          # Webhook URL は秘密情報
vi config.sh                 # 宛先・チェック対象を書く
./server-notify.sh --test    # 疎通確認（テストメッセージが届く）
./server-notify.sh --dry-run # 送信せず内容だけ確認
```

### 通知先の取り方

| 宛先 | Webhook URL の取得 | 設定する配列 |
|---|---|---|
| Discord | チャンネル設定 → 連携サービス → ウェブフックを作成 | `DISCORD_WEBHOOK_URLS` |
| Slack | Slack App → Incoming Webhooks を有効化 → Add New Webhook | `SLACK_WEBHOOK_URLS` |
| Google Chat | スペース → アプリと統合 → Webhook → 追加 | `GOOGLE_CHAT_WEBHOOK_URLS` |

複合したい場合は該当する配列の両方に URL を入れる。同じ配列に複数書けば同一サービスの複数チャンネルへも送れる。

```bash
DISCORD_WEBHOOK_URLS=("https://discord.com/api/webhooks/.../...")
GOOGLE_CHAT_WEBHOOK_URLS=("https://chat.googleapis.com/v1/spaces/.../messages?key=...&token=...")
```

## 出力例

```
[CRIT] web01 サーバー状態レポート

■ SSL証明書の期限
  ✅ www.example.com:443          残り  62日 (2026-11-16)
  🚨 old.example.com:443          残り   4日 (2026-09-19)

■ ディスク容量
  ✅ /               48%  使用 103.4GB / 227.1GB  (空き 112.2GB)
     増加 +1.2GB/日 (過去14.000日) → 満杯まで約 93日

■ ログ容量
  ⚠️ /var/log  合計 3.8GB
        3.8GB  /var/log/journal
               → 削減: sudo journalctl --vacuum-size=500M

■ Docker
     Images         全 23件(使用中 17)  使用 17.61GB   削除可 10.2GB
     Build Cache    全144件(使用中  0)  使用 3.238GB   削除可 3.0GB
  ⚠️ 削除できそうな容量 合計 18.8GB
     停止済みコンテナ 14件 / 未参照イメージ 5件 / 未使用ボリューム 6件
     回収例: docker system prune -f  /  docker builder prune -f  /  docker image prune -a
  🚨 コンテナ停止中: app-worker (status=exited, restart=always)

■ メモリ
  ⚠️ スワップ使用率 99% (4.0GB / 4.0GB)
        2.7GB  java
      259.0MB  mariadbd

■ バックアップ鮮度
  🚨 /var/backups/db.sql.gz が 51時間 更新されていません (許容 26h)

web01 ・ 2026-09-15 09:00 ・ server-notify.sh
```

通知は全体レベルに応じて色が付く（OK=緑 / WARN=黄 / CRIT=赤）。

## 使い方

```
server-notify.sh [オプション]

  -c, --config FILE   設定ファイル（既定: 同ディレクトリの config.sh）
  -n, --dry-run       送信せず標準出力に表示するだけ
  -q, --quiet         標準出力に出さない（cron 向け）
  -v, --verbose       送信結果などを stderr に出す
      --only LIST     指定チェックのみ実行（カンマ区切り）
      --level LEVEL   送信閾値を上書き（ok|warn|crit）
      --mode MODE     full|issues（issues は WARN 以上の節だけ本文に載せる）
      --test          疎通確認用のテストメッセージを送る
  -h, --help          ヘルプ

終了コード: 0=OK / 1=WARN / 2=CRIT / 3=設定・送信エラー
```

## チェック項目

| 名前 | 内容 | 主な閾値 |
|---|---|---|
| `ssl` | SSL 証明書の残日数。ドメインへ実際に TLS 接続して確認するため、**証明書がこのサーバーに無くても（CDN・別のリバースプロキシ配下でも）チェックできる**。ローカルの PEM も glob 指定可 | `SSL_WARN_DAYS=21` / `SSL_CRIT_DAYS=7` |
| `disk` | 各マウントの使用率・inode 使用率。さらに使用量の履歴から**増加ペースと「満杯まであと何日」を予測** | `DISK_WARN_PCT=80` / `90`、`DISK_ETA_WARN_DAYS=60` |
| `logdir` | ログフォルダの合計サイズ、内訳上位 N 件、単体で肥大したログファイル。`/var/log/journal` が大きい場合は削減コマンドを併記 | `LOGDIR_WARN_MB=2048`、`LOGFILE_WARN_MB=500` |
| `docker` | `docker system df` の**削除可能容量**（イメージ/コンテナ/ボリューム/ビルドキャッシュ別）、停止済みコンテナ・未参照イメージ・未使用ボリュームの件数、回収コマンドの提示。加えて「restart=always なのに停止している」「unhealthy」「再起動が多い」コンテナを検出 | `DOCKER_RECLAIM_WARN_MB=10240` |
| `memory` | 利用可能メモリ率、スワップ使用率（多い場合はスワップを食っているプロセス上位 3 件） | `MEM_WARN_AVAIL_PCT=15`、`SWAP_WARN_PCT=80` |
| `load` | 5 分平均ロード ÷ コア数、稼働日数 | `LOAD_WARN_RATIO=1.5` |
| `http` | 各 URL の HTTP ステータスと応答時間。期待コードを指定できる（`"URL\|403"`） | `HTTP_SLOW_SEC=3.0` |
| `updates` | 未適用の apt 更新数（セキュリティ更新は別カウント）、再起動要求フラグ、長期未再起動 | `UPTIME_WARN_DAYS=180` |
| `systemd` | failed 状態のユニット（除外パターン指定可） | — |
| `backup` | バックアップファイル／ディレクトリの最終更新からの経過時間。定期ジョブが止まっていることに気づける | `BACKUP_MAX_AGE_HOURS=26` |

実行するチェックは `ENABLED_CHECKS` で取捨選択する。

## 通知量のコントロール

| 設定 | 意味 |
|---|---|
| `NOTIFY_LEVEL` | `ok`=毎回送る（日次サマリ向け） / `warn`=WARN 以上 / `crit`=CRIT のみ |
| `REPORT_MODE` | `full`=全項目 / `issues`=問題のある節だけ本文に載せる |
| `SUPPRESS_REPEAT_MIN` | 同レベルの通知を指定分数だけ抑制する。**レベルが悪化したときと復旧したときは抑制されない** |

障害が解消して OK に戻った回は、`NOTIFY_LEVEL` に関わらず「復旧」通知が 1 回だけ飛ぶ。

## cron 運用例

```cron
# 毎朝 9:00 に全項目のサマリを送る
0 9 * * * /opt/server-notify/server-notify.sh -q

# 15 分ごとに点検し、WARN 以上のときだけ問題箇所を送る（3 時間は連投しない）
*/15 * * * * /opt/server-notify/server-notify.sh -q --level warn --mode issues
```

15 分間隔の方は `config.sh` の `SUPPRESS_REPEAT_MIN=180` を併用する。
多重起動は `flock` で防いでいるので、前回の実行が終わっていなければ後続は何もせず終了する。

## チェックを追加する

`lib/checks.sh` に `check_<名前>()` を定義し、`ENABLED_CHECKS` に `<名前>` を足すだけでよい。
本文は次の 3 つの関数で組み立てる。

```bash
check_example() {
  section "見出し"
  item "$LV_WARN" "問題のある行"     # LV_OK / LV_WARN / LV_CRIT / LV_INFO
  note "アイコン無しの補足行"
}
```

`item` に渡したレベルが自動的に全体レベル・終了コード・通知色に反映される。

## 既知の制約

- コンテナごとの JSON ログ（`/var/lib/docker/containers/*/`）のサイズは root でないと読めないため、
  `docker system df` の集計値で代替している。厳密に見たい場合は root で実行するか、
  `/etc/docker/daemon.json` で `log-opts` の `max-size` / `max-file` を設定してログ肥大自体を防ぐのが確実。
- `docker` の削除可能容量は「回収コマンドの提示」までで、**削除は一切実行しない**。
- `apt-get -s upgrade` を使うため `updates` チェックは 1〜2 秒かかる。
- 通知本文はサービスごとの上限（Discord 4000 / Slack 2900 / Google Chat 3900 文字）で自動的に切り詰める。
  対象が多い場合は `REPORT_MODE=issues` を使う。

## ライセンス・権利表記

このリポジトリは **閲覧していただくことを目的として** 公開しています。

ライセンスは付与していないため、著作権法の原則どおり著作権者がすべての権利を留保します。
コードの複製・改変・再配布は許可していません。
（GitHub 上での fork は、public リポジトリに対して
[GitHub 利用規約](https://docs.github.com/site-policy/github-terms/github-terms-of-service)
が許諾している範囲の行為として可能です。）

利用をご希望の場合はご連絡ください。
