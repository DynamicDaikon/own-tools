#!/bin/bash
set -euo pipefail

# --- 設定 ---
DC="docker-compose"
basePath="$HOME/git/shn/shinkikan/bo"
dockerDir="${basePath}/docker"
buildPath="${basePath}/backend"
# コンテナ内で相対指定する JAR パス（コンテナ内の作業ディレクトリは /backend を想定）
CONTAINER_JAR_PATH="./build/libs/bo-backend-0.0.1-SNAPSHOT.jar"
# ホスト側のビルド成果物（確認用）
HOST_JAR_PATH="${buildPath}/build/libs/bo-backend-0.0.1-SNAPSHOT.jar"

# 待ち時間設定（秒） — 必要に応じて環境変数で上書き
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-30}
POLL_INTERVAL=${POLL_INTERVAL:-1}
# ----------

options=(
  "up (起動 -d)"
  "ps (状態確認)"
  "logs (ログ表示)"
  "build & run jar (backend をビルドしてコンテナ内で実行)"
  "bash/sh (コンテナに入る)"
  "restart (再起動)"
  "down (停止・削除)"
  "exit (終了)"
)

print_main_menu() {
  local i
  printf "\n========================================\n Docker Compose 管理メニュー \n========================================\n"
  for i in "${!options[@]}"; do
    printf " %d) %s\n" "$((i + 1))" "${options[$i]}"
  done
}

if ! cd "$dockerDir"; then
  echo "error: dockerDir not found: $dockerDir" >&2
  exit 1
fi

# ヘルパ: compose 経由でコンテナIDを取得、駄目なら docker ps でフォールバック
get_container_id() {
  id=$($DC ps -q bo-backend 2>/dev/null || true)
  if [ -n "$id" ]; then
    printf '%s' "$id"
    return 0
  fi
  id=$(docker ps --filter "name=bo-backend" --format '{{.ID}}' | head -n1 || true)
  printf '%s' "$id"
}

# option 4 専用: Ctrl+C はアプリ停止のみに使い、メニューシェルは継続する
run_backend_jar() {
  local rc

  trap 'printf "\napp run canceled. back to menu.\n"' INT

  set +e
  "$DC" exec bo-backend bash -lc "java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005 -jar ${CONTAINER_JAR_PATH}"
  rc=$?
  set -e

  trap - INT

  # Ctrl+C (SIGINT) での終了は正常キャンセルとして扱う
  if [ "$rc" -eq 130 ]; then
    return 0
  fi
  return "$rc"
}

# option 3 専用: Ctrl+C でログ追従を止めてもメニューシェルは継続する
run_logs_follow() {
  local rc

  set +e
  "$DC" logs -f --tail=100
  rc=$?
  set -e

  # Ctrl+C (SIGINT) での終了は正常キャンセルとして扱う
  if [ "$rc" -eq 130 ]; then
    printf "\nlogs canceled. back to menu.\n"
    return 0
  fi
  return "$rc"
}

while true; do
  print_main_menu

  if ! read -r -p "main> choose number (1-${#options[@]}): " choice; then
    echo
    break
  fi

  case "$choice" in
  1)
    "$DC" up -d
    ;;
  2)
    "$DC" ps
    ;;
  3)
    if ! run_logs_follow; then
      echo "error: failed to show logs." >&2
    fi
    ;;
  4)
    # build & run
    if ! pushd "$buildPath" >/dev/null 2>&1; then
      echo "error: buildPath not found: $buildPath" >&2
      popd >/dev/null 2>&1 || true
      continue
    fi

    if ! read -r -p "build> which run environment? (batch or api): " ENV; then
      echo
      popd >/dev/null 2>&1 || true
      continue
    fi
    ENV="${ENV:-}"
    if [ -z "$ENV" ]; then
      echo "break. choose environment" >&2
      popd >/dev/null 2>&1 || true
      continue
    fi

    if [ -x "./gradlew" ]; then
      ./gradlew clean build -Penv="$ENV"
    else
      echo "error: gradlew not found or not executable in $buildPath" >&2
      popd >/dev/null 2>&1 || true
      continue
    fi

    if [ ! -f "$HOST_JAR_PATH" ]; then
      echo "error: not found build package in host: $HOST_JAR_PATH" >&2
      popd >/dev/null 2>&1 || true
      continue
    fi

    # コンテナの存在確認 / 起動 → タイムアウト付きポーリング
    container_id=$(get_container_id)
    if [ -z "$container_id" ]; then
      echo "not running bo-backend container. starting..."
      "$DC" up -d bo-backend
    fi

    start_ts=$(date +%s)
    while true; do
      container_id=$(get_container_id)
      if [ -n "$container_id" ]; then
        break
      fi
      now_ts=$(date +%s)
      if [ $((now_ts - start_ts)) -ge "$TIMEOUT_SECONDS" ]; then
        echo "error: timeout. over ${TIMEOUT_SECONDS} seconds." >&2
        echo "docker-compose ps out:"
        "$DC" ps || true
        echo "docker ps filter out:"
        docker ps --filter "name=bo-backend" --format 'ID={{.ID}} NAME={{.Names}} STATUS={{.Status}}' || true
        container_id=""
        break
      fi
      sleep "${POLL_INTERVAL}"
    done

    if [ -z "$container_id" ]; then
      echo "back to menu" >&2
      popd >/dev/null 2>&1 || true
      continue
    fi

    # 起動（コンテナ内の作業ディレクトリを /backend にして相対パスで起動）
    cd "$dockerDir"
    if ! run_backend_jar; then
      echo "error: backend app exited unexpectedly." >&2
    fi

    popd >/dev/null 2>&1 || true
    ;;
  5)
    # コンテナに入る（ログイン直後のカレントを /backend に設定）
    container=""
    if command -v fzf >/dev/null 2>&1; then
      container=$(docker ps --format "{{.Names}}" | fzf --height 40% --reverse)
    else
      local_idx=""
      mapfile -t containers < <(docker ps --format "{{.Names}}")
      if [ "${#containers[@]}" -eq 0 ]; then
        echo "稼働中のコンテナがありません。" >&2
        continue
      fi
      echo "コンテナを選んでください:"
      for i in "${!containers[@]}"; do
        printf " %d) %s\n" "$((i + 1))" "${containers[$i]}"
      done
      if ! read -r -p "container> choose number (1-${#containers[@]}): " local_idx; then
        echo
        continue
      fi

      if [[ "$local_idx" =~ ^[0-9]+$ ]] && [ "$local_idx" -ge 1 ] && [ "$local_idx" -le "${#containers[@]}" ]; then
        container="${containers[$((local_idx - 1))]}"
      else
        echo "無効な選択です"
        continue
      fi
    fi

    if [ -n "${container:-}" ]; then
      if docker exec "$container" bash -c 'exit 0' 2>/dev/null; then
        docker exec -it "$container" bash -lc "exec bash"
      else
        docker exec -it "$container" sh -c "exec sh"
      fi
    fi
    ;;
  6)
    "$DC" restart
    ;;
  7)
    "$DC" down
    ;;
  8)
    break
    ;;
  *)
    echo "無効な選択です"
    ;;
  esac
  echo "----------------------------------------"
done
