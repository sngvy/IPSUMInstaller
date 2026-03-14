#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

# Проверка на запуск от root
if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Пожалуйста, запустите скрипт от имени root (sudo).${NC}"
    exit 1
fi

echo -e "${B_CYAN}Установка высокопроизводительной защиты IPSUM (RAW Table)...${NC}"

# 1. Зависимости
echo -e "${B_YELLOW}Установка компонентов (ipset, curl, iptables-persistent)...${NC}"
apt-get update -qq && apt-get install -y ipset curl iptables-persistent -qq

# 2. Создание скрипта обновления
S="/usr/local/bin/update-blocklist.sh"
cat << 'EOF' > "$S"
#!/bin/bash
N="bad_ips"
U="https://raw.githubusercontent.com/stamparm/ipsum/refs/heads/master/levels/1.txt"

# Создаем основной сет, если его нет
ipset create -! "$N" hash:net maxelem 1000000

T1=$(mktemp)
T2=$(mktemp)

# Загружаем список
if curl -sSL "$U" | grep -v "#" | awk '{print $1}' > "$T1"; then
    echo "create ${N}_new hash:net maxelem 1000000 -!" > "$T2"
    sed "s/^/add ${N}_new /" "$T1" >> "$T2"
    
    ipset restore < "$T2"
    ipset swap "$N" "${N}_new"
    ipset destroy "${N}_new"
    
    E=$(ipset list "$N" | grep 'Number of entries' | cut -d: -f2 | xargs)
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] Blocked IPs: $E"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Failed to download IPSUM list"
fi
rm -f "$T1" "$T2"
EOF

chmod +x "$S"

# 3. Первый запуск синхронизации
echo -e "${B_YELLOW}Синхронизация с базой IPSUM...${NC}"
"$S"

# 4. Настройка Firewall (Таблица RAW - самая быстрая блокировка)
echo -e "${B_YELLOW}Настройка правил iptables в режиме RAW PREROUTING...${NC}"

# Чистим старые правила, чтобы не дублировать
iptables -D INPUT -m set --match-set bad_ips src -j DROP 2>/dev/null
iptables -t raw -D PREROUTING -m set --match-set bad_ips src -j DROP 2>/dev/null

# Устанавливаем блокировку в таблицу RAW
iptables -t raw -I PREROUTING -m set --match-set bad_ips src -j DROP

# Сохраняем правила
if command -v netfilter-persistent >/dev/null; then
    netfilter-persistent save > /dev/null 2>&1
fi

# 5. Настройка Cron (обновление в 03:15)
echo -e "${B_YELLOW}Добавление задачи в планировщик cron...${NC}"
C_JOB="15 3 * * * $S >> /var/log/blocklist_update.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$S" ; echo "$C_JOB") | crontab -

echo -e "---"
echo -e "${B_GREEN}Установка успешно завершена!${NC}"
echo -e "${BOLD}Тип блокировки:${NC} ${B_CYAN}RAW Table (Нулевая нагрузка на CPU)${NC}"
echo -e "${BOLD}Лог обновлений:${NC} ${B_YELLOW}/var/log/blocklist_update.log${NC}"
echo -e "${BOLD}Статус в iptables:${NC}"
iptables -t raw -L PREROUTING -v -n | grep bad_ips
