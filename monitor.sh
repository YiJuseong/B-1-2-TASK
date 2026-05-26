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

echo "====== SYSTEM MONITOR RESULT ======"

# ---------------------------------------------------------
# 1. Health Check (실패 시 종료)
# ---------------------------------------------------------
echo "[HEALTH CHECK]"
PID=$(pgrep -f "$APP_NAME" | head -n 1)
if [ -z "$PID" ]; then
    echo "Checking process '$APP_NAME'... [FAILED]"
    exit 1
fi
echo "Checking process '$APP_NAME'... [OK] (PID: $PID)"

PORT_CHECK=$(ss -tuln | grep ":$CHECK_PORT ")
if [ -z "$PORT_CHECK" ]; then
    echo "Checking port $CHECK_PORT... [FAILED]"
    exit 1
fi
echo "Checking port $CHECK_PORT... [OK]"

# ---------------------------------------------------------
# 2. 상태 점검 (경고만 출력)
# ---------------------------------------------------------
UFW_STATUS=$(ufw status | grep "Status: active")
if [ -z "$UFW_STATUS" ]; then
    echo "[WARNING] Firewall is inactive."
fi

# ---------------------------------------------------------
# 3. 자원 수집 및 임계값 점검
# ---------------------------------------------------------
echo -e "\n[RESOURCE MONITORING - $APP_NAME (PID: $PID)]"
# top 명령어 대신 ps 명령어를 사용하여 RSS(kb 단위 실제 메모리)를 가져옵니다.
# 또는 컨테이너 내부라면 cat /sys/fs/cgroup/memory.current 활용 가능
APP_RSS_KB=$(ps -p "$PID" -o rss= | tr -d ' ')
if [ -z "$APP_RSS_KB" ]; then
    APP_RSS_KB=0
fi

# KB 단위를 MB 단위로 환산 (소수점 포함)
APP_MEM_MB=$(awk -v kb="$APP_RSS_KB" 'BEGIN {printf "%.2f", kb / 1024}')

# 3-1. 앱의 실시간 CPU 및 MEM 사용량 수집 (top 명령어 활용)
# -b: 배치 모드(텍스트 출력), -n 2: 2회 측정 (첫 번째는 누적치이므로 두 번째 수치를 사용해야 실시간이 됩니다)
# -d 0.5: 측정 간격 0.5초, -p: 특정 PID 지정
TOP_OUTPUT=$(top -b -n 2 -d 0.5 -p "$PID" 2>/dev/null)

# 두 번째 측정 결과에서 해당 PID가 있는 라인을 찾아 CPU와 MEM 추출
APP_RESOURCES=$(echo "$TOP_OUTPUT" | grep -A 100 "PID" | grep -v "PID" | tail -n 1)

APP_CPU=$(echo "$APP_RESOURCES" | awk '{print $9}')
APP_MEM=$(echo "$APP_RESOURCES" | awk '{print $10}')

echo "App Real-time CPU Usage : $APP_CPU%"
echo "App MEM Usage % : $APP_MEM%"
echo "App MEM Usage MB : ${APP_MEM_MB} MB"

#3-2. 앱의 DISK 사용량 및 디스크 자체의 사용 백분율 점검
APP_DIR=$(dirname "$LOG_FILE") 
# df 명령어를 통해 해당 폴더가 속한 디스크의 실제 사용률(%)을 추출합니다.
APP_DISK_USED=$(df -P "$APP_DIR" | tail -1 | awk '{print $5}' | tr -d '%')

echo "Disk Usage : ${APP_DISK_USED}%"

# 임계값 경고 출력
CPU_WARN=$(awk -v cpu="$APP_CPU" -v limit="$CPU_LIMIT" 'BEGIN {print (cpu > limit) ? 1 : 0}')
if [ "$CPU_WARN" -eq 1 ]; then
    echo "[WARNING] App CPU threshold exceeded ($APP_CPU% > $CPU_LIMIT%)"
fi

# MEM 점검
MEM_WARN=$(awk -v mem="$APP_MEM" -v limit="$MEM_LIMIT" 'BEGIN {print (mem > limit) ? 1 : 0}')
if [ "$MEM_WARN" -eq 1 ]; then
    echo "[WARNING] App MEM threshold exceeded ($APP_MEM% > $MEM_LIMIT%)"
fi

# DISK 점검
if [ "$APP_DISK_USED" -gt "$DISK_LIMIT" ]; then
    echo "[WARNING] App DISK threshold exceeded (${APP_DISK_USED}% > ${DISK_LIMIT}%)"
fi

# ---------------------------------------------------------
# 4. 로그 기록
# ---------------------------------------------------------
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
LOG_LINE="[$TIMESTAMP] PID:$PID CPU:$APP_CPU% MEM%:$APP_MEM% MEM MB:$APP_MEM_MB MB DISK_USED:$APP_DISK_USED%"

# 로그 디렉토리 권한 체크 및 기록
echo "$LOG_LINE" >> "$LOG_FILE"
echo -e "\n[INFO] Log appended: $LOG_FILE"

# ---------------------------------------------------------
# 5. 로그 로테이션 (간이 구현: 10MB 초과 시 rotate)
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