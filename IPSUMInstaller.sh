#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Запустите от имени root.${NC}"
    exit 1
fi

echo -e "${B_CYAN}Конфигурация IPSUM Protection${NC}"
echo -e "Выберите метод интеграции:"
echo -e "1) UFW (через before.rules + RAW Table)"
echo -e "2) iptables (прямая таблица RAW)"
read -p "Ваш выбор [1-2]: " FW_CHOICE

case $FW_CHOICE in
    1) 
        MODE="ufw"
        # 1. Устанавливаем UFW, если его нет
        if ! command -v ufw >/dev/null; then
            echo -e "${B_YELLOW}Установка UFW...${NC}"
            apt-get update -qq && apt-get install -y ufw -qq
        fi
        
        # 2. Удаляем iptables-persistent, чтобы он не перезаписывал правила UFW
        if dpkg -l | grep -q iptables-persistent; then
            echo -e "${B_YELLOW}Удаление конфликтующего iptables-persistent...${NC}"
            apt-get purge -y iptables-persistent -qq
        fi
        
        # Устанавливаем общие зависимости
        apt-get install -y ipset -qq
        ;;
    2) 
        MODE="iptables"
        # Для чистого iptables нам как раз нужны утилиты сохранения
        echo -e "${B_YELLOW}Настройка компонентов iptables...${NC}"
        # Сообщаем системе, что установка будет неинтерактивной
        export DEBIAN_FRONTEND=noninteractive

        # Предустанавливаем ответы "Yes" (правда) для iptables-persistent
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        apt-get update -qq && apt-get install -y curl iptables iptables-persistent -qq
        ;;
    *) echo "Неверный выбор. Выход."; exit 1 ;;
esac

S="/usr/local/bin/update-blocklist.sh"
cat << 'EOF' > "$S"
#!/bin/bash
N="bad_ips"
U="https://raw.githubusercontent.com/stamparm/ipsum/refs/heads/master/levels/1.txt"
ipset create -! "$N" hash:net maxelem 1000000
T1=$(mktemp)
T2=$(mktemp)
if curl -sSL "$U" | grep -v "#" | awk '{print $1}' > "$T1"; then
    echo "create ${N}_new hash:net maxelem 1000000 -!" > "$T2"
    sed "s/^/add ${N}_new /" "$T1" >> "$T2"
    ipset restore < "$T2"
    ipset swap "$N" "${N}_new"
    ipset destroy "${N}_new"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] IPSUM list updated"
fi
rm -f "$T1" "$T2"
EOF

chmod +x "$S"
$S

if [ "$MODE" = "ufw" ]; then
    if ! grep -q "bad_ips" /etc/ufw/before.rules; then
        sed -i "1i # IPSUM-Blocklist\n*raw\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -m set --match-set bad_ips src -j DROP\nCOMMIT\n" /etc/ufw/before.rules
        ufw reload
    fi
else
    iptables -t raw -I PREROUTING -m set --match-set bad_ips src -j DROP 2>/dev/null || iptables -t raw -I PREROUTING -m set --match-set bad_ips src -j DROP
    iptables-save > /etc/iptables/rules.v4
fi

C_JOB="15 3 * * * $S >> /var/log/blocklist_update.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$S" ; echo "$C_JOB") | crontab -

read -p "Создать службу systemd для обновления при старте системы? [y/N]: " SYSTEMD_CHOICE
if [[ "$SYSTEMD_CHOICE" =~ ^[Yy]$ ]]; then
    cat << EOF > /etc/systemd/system/ipsum-update.service
[Unit]
Description=Update IPSUM Protection List on Boot
After=network.target

[Service]
Type=oneshot
ExecStart=$S
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ipsum-update.service
    echo -e "${B_YELLOW}Служба systemd создана и включена.${NC}"
fi

echo -e "${B_GREEN}IPSUM Protection успешно настроен через $MODE!${NC}"
