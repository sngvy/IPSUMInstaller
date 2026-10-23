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

S="/usr/local/bin/update-blocklist.sh"
CONF_DIR="/etc/ipsum"
CONF="$CONF_DIR/ipsum.conf"
STATE_DIR="/var/lib/ipsum"
BACKUP_DIR="$CONF_DIR/backup/$(date +%Y%m%d-%H%M%S)"
SET4="ipsum_v4"
OLD_SET="bad_ips"
UPD_UNIT="/etc/systemd/system/ipsum-update.service"
RULE_ARGS=(-m set --match-set "$SET4" src -j DROP)

echo -e "${B_CYAN}Конфигурация IPSUM Protection (ipset)${NC}"

# ------------------------------------------------------------
# Определяем, есть ли предыдущая установка, её режим и уровень списка
# ------------------------------------------------------------
PREV_MODE=""
PREV_LEVEL=""
PREV_URL=""
LEGACY=0
if [ -f "$CONF" ]; then
    PREV_MODE=$( . "$CONF" 2>/dev/null; printf '%s' "$MODE" )
    PREV_LEVEL=$( . "$CONF" 2>/dev/null; printf '%s' "$LEVEL" )
    PREV_URL=$( . "$CONF" 2>/dev/null; printf '%s' "$LIST_URL" )
    echo -e "${B_YELLOW}Найдена установка IPSUM с наборами ipsum_* (режим: ${PREV_MODE:-неизвестен}). Будет обновление.${NC}"
elif [ -f "$S" ]; then
    LEGACY=1
    PREV_MODE=$(sed -n 's/^MODE="\([a-z]*\)".*/\1/p' "$S" | head -n1)
    PREV_LEVEL=$(sed -n 's|.*levels/\([0-9]*\)\.txt.*|\1|p' "$S" | head -n1)
    echo -e "${B_YELLOW}Найдена старая установка IPSUM (набор $OLD_SET, режим: ${PREV_MODE:-неизвестен}). Выполню миграцию.${NC}"
fi

echo -e "Выберите метод интеграции:"
echo -e "1) UFW (правило в before.rules)"
echo -e "2) iptables (таблица raw)"
if [ -n "$PREV_MODE" ]; then
    read -r -p "Ваш выбор [1-2, Enter = оставить $PREV_MODE]: " FW_CHOICE
    if [ -z "$FW_CHOICE" ]; then
        [ "$PREV_MODE" = "ufw" ] && FW_CHOICE=1 || FW_CHOICE=2
    fi
else
    read -r -p "Ваш выбор [1-2]: " FW_CHOICE
fi

case $FW_CHOICE in
    1) MODE="ufw" ;;
    2) MODE="iptables" ;;
    *) echo "Неверный выбор. Выход."; exit 1 ;;
esac

# --- Уровень списка: адрес попадает в него, если есть минимум в N чёрных списках ---
if [ "$LEGACY" -eq 0 ] && [[ "$PREV_LEVEL" =~ ^[1-8]$ ]]; then
    DEFAULT_LEVEL="$PREV_LEVEL"
else
    DEFAULT_LEVEL=3
fi
if [ "$LEGACY" -eq 1 ] && [ -n "$PREV_LEVEL" ]; then
    echo -e "${B_YELLOW}Сейчас используется уровень $PREV_LEVEL. Низкие уровни дают много ложных срабатываний, особенно для клиентов за общим адресом оператора.${NC}"
fi
echo -e "Уровень списка IPSUM от 1 до 8: чем выше, тем короче список и меньше ложных срабатываний."
echo -e "Для ориентира: уровень 1 около 120 тыс. адресов, уровень 3 около 20 тыс., уровень 5 около 5 тыс."
read -r -p "Уровень [1-8, Enter = $DEFAULT_LEVEL]: " LEVEL_INPUT
LEVEL="${LEVEL_INPUT:-$DEFAULT_LEVEL}"
if ! [[ "$LEVEL" =~ ^[1-8]$ ]]; then
    echo "Неверный уровень. Выход."
    exit 1
fi

# ------------------------------------------------------------
# Установка пакетов
# ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

if [ "$MODE" = "ufw" ]; then
    if ! command -v ufw >/dev/null; then
        echo -e "${B_YELLOW}Установка UFW...${NC}"
        apt-get update -qq && apt-get install -y ufw -qq
    fi
    # iptables-persistent перезаписывал бы правила UFW
    if dpkg -l | grep -q iptables-persistent; then
        echo -e "${B_YELLOW}Удаление конфликтующего iptables-persistent...${NC}"
        apt-get purge -y iptables-persistent -qq
    fi
else
    echo -e "${B_YELLOW}Настройка компонентов iptables...${NC}"
    mkdir -p /etc/iptables
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    apt-get update -qq && apt-get install -y iptables iptables-persistent -qq
fi

echo -e "${B_YELLOW}Установка ipset, curl, logrotate...${NC}"
apt-get update -qq && apt-get install -y ipset curl logrotate -qq
if ! command -v ipset >/dev/null || ! command -v curl >/dev/null; then
    echo -e "${B_RED}Не удалось установить ipset или curl. Выход, старые правила не тронуты.${NC}"
    exit 1
fi

# ------------------------------------------------------------
# Резервные копии всего, что будем менять
# ------------------------------------------------------------
install -d -m 700 "$CONF_DIR" "$STATE_DIR" "$BACKUP_DIR"

backup_file() {
    [ -e "$1" ] || return 0
    cp -a "$1" "$BACKUP_DIR/$(echo "$1" | tr '/' '_')"
}

for f in "$S" "$CONF" "$UPD_UNIT" /etc/ufw/before.rules \
         /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    backup_file "$f"
done
crontab -l > "$BACKUP_DIR/crontab" 2>/dev/null
ipset save "$OLD_SET" > "$BACKUP_DIR/ipset-$OLD_SET.save" 2>/dev/null
command -v iptables-save >/dev/null && iptables-save > "$BACKUP_DIR/iptables-save.v4" 2>/dev/null
command -v ip6tables-save >/dev/null && ip6tables-save > "$BACKUP_DIR/ip6tables-save.v6" 2>/dev/null
echo -e "${B_YELLOW}Резервные копии на время миграции: $BACKUP_DIR (удалятся после успешной проверки)${NC}"

# ------------------------------------------------------------
# Конфиг
# ------------------------------------------------------------
{
    echo "# Конфигурация IPSUM Protection."
    echo "# LEVEL: уровень списка 1-8. MIN_ENTRIES: меньше записей не принимаем."
    echo "# LIST_URL: пусто = официальный список нужного уровня, либо адрес своей копии."
    printf 'MODE=%q\n' "$MODE"
    printf 'LEVEL=%q\n' "$LEVEL"
    printf 'MIN_ENTRIES=%q\n' "100"
    printf 'LIST_URL=%q\n' "$PREV_URL"
} > "$CONF.new"
chmod 600 "$CONF.new"
mv "$CONF.new" "$CONF"

# --- Ротация логов: храним только последние 7 дней, чтобы не раздувать диск ---
cat << 'LOGROTATE_EOF' > /etc/logrotate.d/ipsum-protection
/var/log/blocklist_update.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
}
LOGROTATE_EOF

# ------------------------------------------------------------
# Скрипт-обновлятор: ipset, атомарная подмена набора через swap.
# Подкоманды: update (по умолчанию) | restore | ensure-rules
# ------------------------------------------------------------
cat << 'UPDATER_EOF' > "$S"
#!/bin/bash

CONF="/etc/ipsum/ipsum.conf"
if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi

MODE="${MODE:-iptables}"
LEVEL="${LEVEL:-3}"
MIN_ENTRIES="${MIN_ENTRIES:-100}"
LIST_URL="${LIST_URL:-https://raw.githubusercontent.com/stamparm/ipsum/refs/heads/master/levels/${LEVEL}.txt}"

STATE_DIR="/var/lib/ipsum"
SAVE_FILE="$STATE_DIR/ipsets.save"
LEVEL_FILE="$STATE_DIR/level"
SET4="ipsum_v4"
HS4=4096;  MAX4=524288
RULE_ARGS=(-m set --match-set "$SET4" src -j DROP)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

mkdir -p "$STATE_DIR"
if ! command -v ipset >/dev/null; then
    log "[ERROR] ipset не найден"
    exit 1
fi

exec 9>/run/ipsum.lock
if ! flock -w 120 9; then
    log "[ERROR] Не удалось получить блокировку, другой экземпляр занят"
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

create_sets() {
    ipset create -exist "$SET4" hash:net family inet hashsize "$HS4" maxelem "$MAX4"
}

restore_sets() {
    if [ -s "$SAVE_FILE" ]; then
        ipset restore -exist < "$SAVE_FILE" || log "[WARN] Не удалось полностью восстановить $SAVE_FILE"
    fi
}

save_sets() {
    ipset save "$SET4" > "$SAVE_FILE.tmp" && mv "$SAVE_FILE.tmp" "$SAVE_FILE"
    chmod 600 "$SAVE_FILE"
}

set_count() {
    ipset list -t "$1" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}'
}

# Атомарная загрузка: наполняем временный набор и меняем местами с рабочим
load_set() {  # набор, hashsize, maxelem, файл
    local set="$1" hs="$2" me="$3" file="$4" tmp="${1}_tmp" net
    ipset destroy "$tmp" 2>/dev/null
    ipset create "$tmp" hash:net family inet hashsize "$hs" maxelem "$me" || return 1
    if [ -s "$file" ]; then
        if ! sed "s/^/add $tmp /" "$file" | ipset restore -exist 2>/dev/null; then
            log "[WARN] Пакетная загрузка в $set не прошла, добавляю записи по одной"
            ipset flush "$tmp"
            while IFS= read -r net; do
                ipset add -exist "$tmp" "$net" 2>/dev/null || log "[WARN] Пропущена запись: $net"
            done < "$file"
        fi
    fi
    if ! ipset swap "$tmp" "$set"; then
        ipset destroy "$tmp" 2>/dev/null
        return 1
    fi
    ipset destroy "$tmp"
}

# Оставляем только корректные IPv4/CIDR. Для списка блокировки дополнительно
# выбрасываем частные и служебные диапазоны, чтобы не отрезать себя.
filter_list() {  # вход, выход, минимальный префикс, 1 = отсекать частные
    [ -f "$1" ] || { : > "$2"; return 0; }
    awk -v minp="$3" -v priv="$4" '
    {
        gsub(/\r/, ""); sub(/^[ \t]+/, "")
        if ($0 == "" || $0 ~ /^#/) next
        s = $1; p = ""
        i = index(s, "/")
        if (i) { p = substr(s, i + 1); s = substr(s, 1, i - 1); if (p !~ /^[0-9]+$/) next }
        if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
        n = split(s, a, ".")
        for (k = 1; k <= n; k++) if (a[k] + 0 > 255) next
        if (p == "") p = 32
        if (p + 0 < minp || p + 0 > 32) next
        if (priv == 1) {
            if (a[1] == 0 || a[1] == 10 || a[1] == 127 || a[1] >= 224) next
            if (a[1] == 169 && a[2] == 254) next
            if (a[1] == 172 && a[2] >= 16 && a[2] <= 31) next
            if (a[1] == 192 && a[2] == 168) next
            if (a[1] == 100 && a[2] >= 64 && a[2] <= 127) next
        }
        print s "/" p
    }' "$1" | sort -u > "$2"
}

# Правило в таблице raw (режим iptables). В режиме ufw правило лежит в before.rules.
ensure_iptables_rules() {
    local count
    count=$(iptables -t raw -S PREROUTING 2>/dev/null | grep -c "match-set $SET4 src")
    if [ "$count" -ne 1 ]; then
        if [ "$count" -gt 1 ]; then
            log "[WARN] Найдено $count дублей правила, чищу..."
        else
            log "[INFO] Правило отсутствует, создаю"
        fi
        while iptables -t raw -D PREROUTING "${RULE_ARGS[@]}" 2>/dev/null; do :; done
        iptables -t raw -I PREROUTING 1 "${RULE_ARGS[@]}"
    fi
}

# Восстанавливаем правило только если набор уже заполнен: пустой набор
# значит, что защита ещё не настроена, и создавать правило рано.
heal_rules() {
    if [ "$MODE" = "iptables" ] && [ "$(set_count "$SET4")" -gt 0 ]; then
        ensure_iptables_rules
    fi
    return 0
}

cmd_update() {
    local raw="$TMP_DIR/raw" v4="$TMP_DIR/v4" n old prev_level

    create_sets

    if ! curl -fsSL --max-time 60 "$LIST_URL" -o "$raw" || [ ! -s "$raw" ]; then
        log "[ERROR] Не удалось скачать список IPSUM, оставляю текущий набор без изменений"
        heal_rules
        return 1
    fi

    filter_list "$raw" "$v4" 16 1
    n=$(wc -l < "$v4")
    old=$(set_count "$SET4")
    prev_level=$(cat "$LEVEL_FILE" 2>/dev/null)

    if [ "$n" -lt "$MIN_ENTRIES" ]; then
        log "[ERROR] В списке всего $n записей (минимум $MIN_ENTRIES), похоже на повреждённый файл. Набор не изменён"
        heal_rules
        return 1
    fi
    # Резкое сокращение при том же уровне: скорее всего, обрезанная загрузка
    if [ "$prev_level" = "$LEVEL" ] && [ "${old:-0}" -ge 1000 ] && [ $((n * 2)) -lt "$old" ]; then
        log "[ERROR] Список сократился с $old до $n записей, похоже на обрезанную загрузку. Набор не изменён"
        heal_rules
        return 1
    fi

    if ! load_set "$SET4" "$HS4" "$MAX4" "$v4"; then
        log "[ERROR] Не удалось загрузить набор ipset"
        return 1
    fi
    echo "$LEVEL" > "$LEVEL_FILE"
    save_sets
    [ "$MODE" = "iptables" ] && ensure_iptables_rules

    log "[SUCCESS] Список IPSUM обновлён: уровень $LEVEL, записей $n (режим $MODE, ipset)"
    return 0
}

case "${1:-update}" in
    update)       cmd_update ;;
    restore)      create_sets; restore_sets ;;
    ensure-rules) create_sets; [ "$MODE" = "iptables" ] && ensure_iptables_rules ;;
    *) echo "Использование: $0 [update|restore|ensure-rules]"; exit 1 ;;
esac
UPDATER_EOF

chmod 700 "$S"

# ------------------------------------------------------------
# Служба, которая создаёт наборы до загрузки файрвола. Без неё правила
# с --match-set не загрузятся после ребута (iptables-restore падает
# целиком, а UFW не применяет before.rules, если набора ещё нет).
# ------------------------------------------------------------
cat << EOF > /etc/systemd/system/ipsum-ipset.service
[Unit]
Description=Create and restore IPSUM ipsets before firewall
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target ufw.service netfilter-persistent.service iptables.service ip6tables.service
Wants=network-pre.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$S restore

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ipsum-ipset.service >/dev/null 2>&1

# ------------------------------------------------------------
# Первый запуск: создаём наборы и наполняем их.
# Старые правила пока не трогаем: если загрузка не удалась, защита остаётся.
# ------------------------------------------------------------
"$S" restore
echo -e "${B_YELLOW}Загрузка списка IPSUM (уровень $LEVEL)...${NC}"
if ! "$S" update; then
    N=$(ipset list -t "$SET4" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')
    if [ "${N:-0}" -eq 0 ]; then
        echo -e "${B_RED}Набор $SET4 пуст, список не загрузился. Старые правила оставлены без изменений.${NC}"
        echo -e "${B_YELLOW}Проверьте доступ к списку и запустите установку снова.${NC}"
        exit 1
    fi
    echo -e "${B_YELLOW}Скачать новый список не вышло, продолжаю с сохранённым набором ($N записей).${NC}"
fi

# ------------------------------------------------------------
# Миграция: удаление старых правил со старым набором bad_ips
# ------------------------------------------------------------
remove_legacy_ufw_block() {
    local f="/etc/ufw/before.rules" start end
    [ -f "$f" ] || return 0
    start=$(grep -n '^# IPSUM-Blocklist$' "$f" | head -n1 | cut -d: -f1)
    [ -n "$start" ] || return 0
    # Блок короткий: от комментария до первой строки COMMIT. Если структура не
    # совпала, файл не трогаем, чтобы не удалить лишнего.
    end=$(awk -v s="$start" 'NR > s && NR <= s + 8 && /^COMMIT$/ {print NR; exit}' "$f")
    if [ -z "$end" ]; then
        echo -e "${B_YELLOW}В $f найден блок IPSUM нестандартного вида, удалите его вручную (строки от '# IPSUM-Blocklist' до COMMIT).${NC}"
        return 1
    fi
    sed -i "${start},${end}d" "$f"
    # убираем пустую строку, оставшуюся на месте блока
    sed -i "${start}{/^\$/d}" "$f"
    echo -e "${B_YELLOW}Из $f удалён блок старой версии IPSUM.${NC}"
}

remove_legacy_raw_rule() {
    # reload UFW не чистит таблицу raw, поэтому удаляем и правило, и его дубли
    while iptables -t raw -D PREROUTING -m set --match-set "$OLD_SET" src -j DROP 2>/dev/null; do :; done
}

destroy_legacy_set() {
    ipset destroy "$OLD_SET" 2>/dev/null
}

# ------------------------------------------------------------
# UFW: before.rules
# ------------------------------------------------------------
setup_ipset_block_ufw() {
    echo -e "${B_YELLOW}Подключение наборов IPSUM к UFW (before.rules)...${NC}"
    local f="/etc/ufw/before.rules" tmp
    [ -f "$f" ] || return 0

    # Убираем прошлую версию блока, чтобы повторный запуск не плодил дубли
    sed -i '/# --- IPSUM-IPSet: begin ---/,/# --- IPSUM-IPSet: end ---/d' "$f"

    tmp=$(mktemp)
    if grep -q '^# End required lines' "$f"; then
        # Ставим правило самым первым в цепочке, до разрешающих правил UFW
        awk -v s4="$SET4" '
            { print }
            /^# End required lines/ && !done {
                print "# --- IPSUM-IPSet: begin ---"
                print "-A ufw-before-input -m set --match-set " s4 " src -j DROP"
                print "# --- IPSUM-IPSet: end ---"
                done = 1
            }
        ' "$f" > "$tmp"
    else
        echo -e "${B_YELLOW}В $f нет маркера '# End required lines', вставляю перед COMMIT (проверьте порядок правил).${NC}"
        awk -v s4="$SET4" '
            /^COMMIT/ && !done {
                print "# --- IPSUM-IPSet: begin ---"
                print "-A ufw-before-input -m set --match-set " s4 " src -j DROP"
                print "# --- IPSUM-IPSet: end ---"
                done = 1
            }
            { print }
        ' "$f" > "$tmp"
    fi
    # cat вместо mv: сохраняем права и владельца исходного файла
    cat "$tmp" > "$f"
    rm -f "$tmp"
}

remove_ipset_block_ufw() {
    local f="/etc/ufw/before.rules"
    [ -f "$f" ] || return 0
    sed -i '/# --- IPSUM-IPSet: begin ---/,/# --- IPSUM-IPSet: end ---/d' "$f"
}

remove_new_raw_rule() {
    while iptables -t raw -D PREROUTING "${RULE_ARGS[@]}" 2>/dev/null; do :; done
}

restore_ufw_backups() {
    [ -e "$BACKUP_DIR/_etc_ufw_before.rules" ] && cat "$BACKUP_DIR/_etc_ufw_before.rules" > /etc/ufw/before.rules
}

ufw_is_active() {
    ufw status 2>/dev/null | grep -q "^Status: active"
}

if [ "$MODE" = "ufw" ]; then
    remove_legacy_ufw_block
    setup_ipset_block_ufw

    if ufw_is_active; then
        if ! ufw reload; then
            echo -e "${B_RED}ufw reload не прошёл, возвращаю прежний before.rules из $BACKUP_DIR${NC}"
            restore_ufw_backups
            ufw reload
            exit 1
        fi
    else
        echo -e "${B_RED}ВНИМАНИЕ: UFW сейчас не включён, правила применятся только после 'ufw enable'.${NC}"
        echo -e "${B_YELLOW}Сначала убедитесь, что разрешён SSH (ufw allow <порт>/tcp), иначе потеряете доступ.${NC}"
    fi

    # Блокировку теперь делает UFW: убираем старое правило из raw (и его дубли)
    remove_legacy_raw_rule
    remove_new_raw_rule
    destroy_legacy_set

    systemctl enable ufw 2>/dev/null
    if systemctl is-enabled ufw &>/dev/null; then
        echo -e "${B_GREEN}UFW включён в автозагрузку, before.rules применится при ребуте.${NC}"
    else
        echo -e "${B_RED}ВНИМАНИЕ: ufw не в автозагрузке. Выполните: ufw enable${NC}"
    fi
else
    # Новое правило уже создано обновлятором, убираем старое
    "$S" ensure-rules
    remove_legacy_raw_rule

    # Переход с UFW на iptables, а также чистка блока старой версии, если он остался в UFW
    remove_legacy_ufw_block
    remove_ipset_block_ufw
    command -v ufw >/dev/null && ufw_is_active && ufw reload
    destroy_legacy_set

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6

    systemctl enable netfilter-persistent 2>/dev/null || systemctl enable iptables-persistent 2>/dev/null
    systemctl restart netfilter-persistent 2>/dev/null

    if systemctl is-enabled netfilter-persistent &>/dev/null; then
        echo -e "${B_GREEN}netfilter-persistent включён, правила переживут перезагрузку.${NC}"
    else
        echo -e "${B_RED}ВНИМАНИЕ: не удалось включить netfilter-persistent. После ребута правила iptables могут слететь!${NC}"
    fi
fi

# ------------------------------------------------------------
# Cron и служба обновления при старте
# ------------------------------------------------------------
C_JOB="15 3 * * * $S >> /var/log/blocklist_update.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$S" ; echo "$C_JOB") | crontab -

if [ -f "$UPD_UNIT" ]; then
    SYSTEMD_CHOICE="y"
    echo -e "${B_YELLOW}Найдена служба ipsum-update, обновляю её файл (без устаревшего создания набора).${NC}"
else
    read -r -p $'\033[1;33mСоздать службу systemd для обновления при старте системы? [y/N]: \033[0m' SYSTEMD_CHOICE
fi
if [[ "$SYSTEMD_CHOICE" =~ ^[Yy]$ ]]; then
    cat << EOF > "$UPD_UNIT"
[Unit]
Description=Update IPSUM Protection List on Boot
After=network-online.target ipsum-ipset.service
Wants=network-online.target
Requires=ipsum-ipset.service

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

echo -e "${B_GREEN}IPSUM Protection успешно настроен через $MODE (ipset).${NC}"
echo -e "${B_CYAN}Полезные пути:${NC}"
echo -e "  Конфиг (уровень, режим):          $CONF"
echo -e "  Скрипт обновления:                $S"
echo -e "  Лог обновлений:                   /var/log/blocklist_update.log"
echo -e "  Проверка:                         ipset list -t $SET4 | grep 'Number of entries'"
if [ "$MODE" = "ufw" ]; then
    echo -e "                                    iptables -S ufw-before-input | grep match-set"
else
    echo -e "                                    iptables -t raw -S PREROUTING"
fi

# ------------------------------------------------------------
# Проверка результата. Бэкап удаляется только если всё реально работает,
# иначе он остаётся для ручного отката.
# ------------------------------------------------------------
verify_migration() {
    local n
    ipset list -n 2>/dev/null | grep -qx "$SET4" || { echo "нет набора $SET4"; return 1; }
    n=$(ipset list -t "$SET4" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')
    [ "${n:-0}" -gt 0 ] || { echo "набор $SET4 пуст"; return 1; }
    if [ "$MODE" = "ufw" ]; then
        iptables -S ufw-before-input 2>/dev/null | grep -q "match-set $SET4" \
            || { echo "правило ipset не найдено в ufw-before-input (UFW выключен?)"; return 1; }
    else
        iptables -t raw -C PREROUTING "${RULE_ARGS[@]}" 2>/dev/null \
            || { echo "правило ipset не найдено в таблице raw"; return 1; }
    fi
    iptables -t raw -S PREROUTING 2>/dev/null | grep -q "match-set $OLD_SET" \
        && { echo "в таблице raw остались правила со старым набором $OLD_SET"; return 1; }
    ipset list -n 2>/dev/null | grep -qx "$OLD_SET" \
        && { echo "старый набор $OLD_SET не удалён (на него ещё ссылаются правила)"; return 1; }
    systemctl is-enabled ipsum-ipset.service &>/dev/null \
        || { echo "ipsum-ipset.service не включён"; return 1; }
    crontab -l 2>/dev/null | grep -qF "$S" || { echo "нет задания cron"; return 1; }
    return 0
}

if [ -d "$BACKUP_DIR" ]; then
    if REASON=$(verify_migration); then
        rm -rf "$BACKUP_DIR"
        rmdir "$CONF_DIR/backup" 2>/dev/null
        echo -e "${B_GREEN}Миграция проверена, резервные копии удалены.${NC}"
    else
        echo -e "${B_YELLOW}Проверка не пройдена ($REASON), резервные копии оставлены: $BACKUP_DIR${NC}"
    fi
fi
