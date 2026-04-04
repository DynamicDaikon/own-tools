#!/bin/bash
set -euo pipefail

# ---- 引数チェック ----
# 使い方: ./downloadCloudWatch.sh <log-stream-name>
# 例:     ./downloadCloudWatch.sh bo-dev-batch-jobdef-cmn/default/09d3f80e99cb4e0d9e789f3ffe501f42
if [ $# -ne 2 ]; then
  echo "Usage: $0 <log-event> <log-stream-name>" >&2
  echo "  例: $0 aws/job/batch bo-dev-batch-jobdef-cmn/default/09d3f80e99cb4e0d9e789f3ffe501f42" >&2
  exit 1
fi

# ---- 設定 ----
REGION="ap-northeast-1"
# 第1引数：ロググループ "/aws/batch/job"
LOG_GROUP=$1
# 第2引数: stream-name / default / hash
LOG_STREAM="$2"

# 取得期間を限定したい場合は下面を編集（空にするとストリーム全域を取得する）
# 例: FROM_HUMAN='2026-03-01 00:00:00 +09:00'
FROM_HUMAN=''
TO_HUMAN=''

# 出力ファイル
OUT_NDJSON="cw_${LOG_STREAM##*/}_events.ndjson"

# ---- 日付を ms に変換（指定があれば） ----
if [ -n "$FROM_HUMAN" ]; then
  FROM_MS=$(($(date -d "$FROM_HUMAN" +%s) * 1000))
fi
if [ -n "$TO_HUMAN" ]; then
  TO_MS=$(($(date -d "$TO_HUMAN" +%s) * 1000))
fi

# 初期化
: >"$OUT_NDJSON"

# ---- get-log-events でページング取得 ----
prev_token=""
first_call=true

while :; do
  if $first_call; then
    # 初回（--start-from-head で最初から）
    cmd=(aws logs get-log-events --region "$REGION"
      --log-group-name "$LOG_GROUP"
      --log-stream-name "$LOG_STREAM"
      --start-from-head)
    [ -n "${FROM_MS:-}" ] && cmd+=(--start-time "$FROM_MS")
    [ -n "${TO_MS:-}" ] && cmd+=(--end-time "$TO_MS")
    first_call=false
  else
    # 続き（next token を指定）
    cmd=(aws logs get-log-events --region "$REGION"
      --log-group-name "$LOG_GROUP"
      --log-stream-name "$LOG_STREAM"
      --next-token "$prev_token")
  fi

  resp="$("${cmd[@]}")"

  # events[] を NDJSON で追記
  echo "$resp" | jq -c '.events[]' >>"$OUT_NDJSON"

  # 次トークンを確認（終了条件）
  token=$(echo "$resp" | jq -r '.nextForwardToken // empty')
  if [ -z "$token" ]; then
    break
  fi
  # トークンが変わらなければ終了（繰り返し防止）
  if [ "$token" = "$prev_token" ]; then
    break
  fi
  prev_token="$token"
done

echo "完了: $OUT_NDJSON を作成しました。"

# 大きいファイルは S3 にコピーする例（必要なら有効化）
# aws s3 cp "$OUT_NDJSON" s3://your-bucket/path/
