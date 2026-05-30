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
# 해당 앱 이름을 가진 모든 PID를 콤마(,)로 연결 (ps 명령어 입력용)
PID_LIST=$(pgrep -f "$APP_NAME" | tr '\n' ',' | sed 's/,$//')

if [ -z "$PID_LIST" ]; then
    echo "Checking process '$APP_NAME'... [FAILED]"
    exit 1
fi
echo "Checking process '$APP_NAME'... [OK] (PIDs: $PID_LIST)"

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
echo -e "\n[RESOURCE MONITORING - $APP_NAME]"
# 3-1. 모든 관련 프로세스의 RSS(KB), CPU(%), MEM(%)을 가져와서 awk로 합산
RESOURCE_SUM=$(ps -p "$PID_LIST" -o rss=,pcpu=,pmem= | awk '
BEGIN {rss=0; cpu=0; mem=0}
{
    rss += $1
    cpu += $2
    mem += $3
}
END {
    printf "%.2f %.1f %.1f", rss/1024, cpu, mem
}')

# 결과를 각각의 변수에 할당
APP_MEM_MB=$(echo "$RESOURCE_SUM" | awk '{print $1}')
APP_CPU=$(echo "$RESOURCE_SUM" | awk '{print $2}')
APP_MEM=$(echo "$RESOURCE_SUM" | awk '{print $3}')

echo "App Total Real-time CPU Usage : $APP_CPU%"
echo "App Total MEM Usage % : $APP_MEM%"

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