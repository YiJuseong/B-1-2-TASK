#!/bin/bash

# ---------------------------------------------------------
# 환경 설정
# ---------------------------------------------------------
APP_NAME="agent-app-leak"
CHECK_PORT=15034
LOG_FILE="/var/log/agent-app/monitor.log"
CPU_LIMIT=20
MEM_LIMIT=10
DISK_LIMIT=80

# ---------------------------------------------------------
# 1분 동안 2초 주기로 총 30회 반복 실행 (루프 내장)
# ---------------------------------------------------------
for i in {1..30}; do
    # 루프 시작 시간 기록 (정확한 2초 타이밍 보정용)
    START_TIME=$(date +%s.%N)

    # -----------------------------------------------------
    # Health Check (실패 시 로그 기록 후 이번 루프만 패스)
    # -----------------------------------------------------
    PID_LIST=$(pgrep -f "$APP_NAME" | tr '\n' ',' | sed 's/,$//')

    if [ -z "$PID_LIST" ]; then
        TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[$TIMESTAMP] Process '$APP_NAME' not found." >> "$LOG_FILE"
        sleep 2
        continue
    fi

    PORT_CHECK=$(ss -tuln | grep ":$CHECK_PORT ")
    if [ -z "$PORT_CHECK" ]; then
        TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[$TIMESTAMP] Port $CHECK_PORT is down." >> "$LOG_FILE"
        sleep 2
        continue
    fi

    # -----------------------------------------------------
    # 자원 수집 및 임계값 점검
    # -----------------------------------------------------
    # 1) 메모리 수집 (ps 기반 정확한 측정)
    RESOURCE_SUM=$(ps -p $PID_LIST -o rss=,pmem= | awk '
    BEGIN {rss=0; mem=0}
    { rss += $1; mem += $2 }
    END { printf "%.2f %.1f", rss/1024, mem }')

    APP_MEM_MB=$(echo "$RESOURCE_SUM" | awk '{print $1}')
    APP_MEM=$(echo "$RESOURCE_SUM" | awk '{print $2}')

    # 2) CPU 실시간 측정 (샘플링 간격을 0.8초로 늘려 순간적인 스파이크 노이즈 완화)
    CURRENT_CPU=$(top -b -n 2 -d 0.8 -p "$PID_LIST" 2>/dev/null | awk -v pids="$PID_LIST" '
    BEGIN {
        split(pids, arr, ","); for (i in arr) p_map[arr[i]] = 1;
        cpu_sum = 0; iteration = 0;
    }
    /top - / { iteration++ }
    iteration == 2 && $1 in p_map { cpu_sum += $9 }
    END { printf "%.1f", cpu_sum }')

    if [ -z "$CURRENT_CPU" ] || [ "$CURRENT_CPU" == "" ]; then
        CURRENT_CPU="0.0"
    fi

    APP_CPU="$CURRENT_CPU"
    
    # 4) 디스크 사용량 점검
    APP_DIR=$(dirname "$LOG_FILE") 
    APP_DISK_USED=$(df -P "$APP_DIR" | tail -1 | awk '{print $5}' | tr -d '%')

    # -----------------------------------------------------
    # 임계값 경고 처리 (로그 파일에 직접 경고문 추가)
    # -----------------------------------------------------
    CPU_WARN=$(awk -v cpu="$APP_CPU" -v limit="$CPU_LIMIT" 'BEGIN {print (cpu > limit) ? 1 : 0}')
    if [ "$CPU_WARN" -eq 1 ]; then
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [WARNING] App CPU threshold exceeded ($APP_CPU% > $CPU_LIMIT%)" >> "$LOG_FILE"
    fi

    MEM_WARN=$(awk -v mem="$APP_MEM" -v limit="$MEM_LIMIT" 'BEGIN {print (mem > limit) ? 1 : 0}')
    if [ "$MEM_WARN" -eq 1 ]; then
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [WARNING] App MEM threshold exceeded ($APP_MEM% > $MEM_LIMIT%)" >> "$LOG_FILE"
    fi

    if [ "$APP_DISK_USED" -gt "$DISK_LIMIT" ]; then
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [WARNING] App DISK threshold exceeded (${APP_DISK_USED}% > ${DISK_LIMIT}%)" >> "$LOG_FILE"
    fi

    # -----------------------------------------------------
    # 로그 최종 기록 (디스크 오타 완벽 복구 버전)
    # -----------------------------------------------------
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    LOG_LINE="[$TIMESTAMP] PIDs:[$PID_LIST] CPU:$APP_CPU% MEM%:$APP_MEM% MEM MB:$APP_MEM_MB MB DISK_USED:${APP_DISK_USED}%"
    echo "$LOG_LINE" >> "$LOG_FILE"

    # -----------------------------------------------------
    # 정밀 2초 타이밍 보정 (오차 계산 Sleep)
    # -----------------------------------------------------
    END_TIME=$(date +%s.%N)
    ELAPSED=$(awk -v start="$START_TIME" -v end="$END_TIME" 'BEGIN {print end - start}')
    SLEEP_TIME=$(awk -v elapsed="$ELAPSED" 'BEGIN { sleep = 2.0 - elapsed; print (sleep > 0) ? sleep : 0 }')
    
    # 30번째 마지막 루프가 아니면 정밀 대기 실행
    if [ "$i" -lt 30 ]; then
        sleep $SLEEP_TIME
    fi
done

# ---------------------------------------------------------
# 5. 로그 로테이션 (1분 주기가 완전히 끝난 후 최종 체크)
# ---------------------------------------------------------
MAX_SIZE=10485760 # 10MB
if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt $MAX_SIZE ]; then
    for i in {9..1}; do
        [ -f "$LOG_FILE.$i" ] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
    done
    mv "$LOG_FILE" "$LOG_FILE.1"
    touch "$LOG_FILE"
    chmod 664 "$LOG_FILE"
fi