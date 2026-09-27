#!/bin/bash
# =====================================================
# Ubuntu Server - Sistem Məlumatları Skripti
# İstifadə: sudo bash sistem_melumat.sh
# =====================================================

# Rəng kodları
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Skriptin özünün olduğu qovluq (nə yerdən işlədilsə də, nəticə həmişə orada saxlanılır)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Çıxış faylının adı: hostname_YYYY-MM-DD_HH-MM.txt
VM_ADI="$(hostname)"
TARIX="$(date +%Y-%m-%d_%H-%M)"
CIXIS_FAYLI="${SCRIPT_DIR}/${VM_ADI}_${TARIX}.txt"

# Bütün çıxışı EYNİ ANDA həm terminala (rəngli) göstər, həm də fayla (rəngsiz, təmiz mətn) yaz
exec > >(tee >(sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g' > "$CIXIS_FAYLI")) 2>&1

line() {
    echo -e "${CYAN}--------------------------------------------------${NC}"
}

header() {
    echo ""
    line
    echo -e "${YELLOW}$1${NC}"
    line
}

# ---------------------------------------------------
header "1. ÜMUMİ SİSTEM MƏLUMATI"
echo -e "${GREEN}Hostname:${NC} $(hostname)"
echo -e "${GREEN}OS:${NC} $(grep PRETTY_NAME /etc/os-release | cut -d '"' -f2)"
echo -e "${GREEN}Kernel:${NC} $(uname -r)"
echo -e "${GREEN}Arxitektura:${NC} $(uname -m)"
echo -e "${GREEN}Uptime:${NC} $(uptime -p 2>/dev/null || uptime)"

# ---------------------------------------------------
header "2. TARİX VƏ SAAT"
echo -e "${GREEN}Sistem saatı:${NC} $(date)"
echo -e "${GREEN}Timezone:${NC} $(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3, $4, $5}')"
if command -v timedatectl >/dev/null 2>&1; then
    NTP_STATUS=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    echo -e "${GREEN}NTP sinxronizasiyası:${NC} ${NTP_STATUS:-Naməlum}"
fi

# ---------------------------------------------------
header "3. ŞƏBƏKƏ / IP MƏLUMATLARI"

# Əsas fiziki interfeysi tapmağa çalışırıq (loopback, docker, bridge, veth istisna)
MAIN_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker|br-|veth|virbr)' | head -n1)

if [ -z "$MAIN_IF" ]; then
    echo "Əsas şəbəkə interfeysi tapılmadı."
else
    IP_ADDR=$(ip -4 addr show "$MAIN_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
    GATEWAY=$(ip route | grep default | awk '{print $3}')
    echo -e "${GREEN}İnterfeys:${NC} $MAIN_IF"
    echo -e "${GREEN}IP ünvanı:${NC} $IP_ADDR"
    echo -e "${GREEN}Gateway:${NC} $GATEWAY"

    # Statik / Dinamik yoxlanışı (bir neçə üsulla, sırayla yoxlanılır)
    IP_METHOD=""
    IP_SOURCE=""

    # Üsul 1: NetworkManager (nmcli)
    if command -v nmcli >/dev/null 2>&1; then
        CONN_NAME=$(nmcli -t -f DEVICE,NAME connection show --active 2>/dev/null | grep "^$MAIN_IF:" | cut -d: -f2)
        if [ -n "$CONN_NAME" ]; then
            METHOD=$(nmcli -g ipv4.method connection show "$CONN_NAME" 2>/dev/null)
            case "$METHOD" in
                manual) IP_METHOD="STATİK"; IP_SOURCE="NetworkManager: $CONN_NAME" ;;
                auto)   IP_METHOD="DİNAMİK (DHCP)"; IP_SOURCE="NetworkManager: $CONN_NAME" ;;
            esac
        fi
    fi

    # Üsul 2: Netplan yaml faylları
    if [ -z "$IP_METHOD" ] && [ -d /etc/netplan ]; then
        if grep -rq "dhcp4:\s*true" /etc/netplan/*.yaml 2>/dev/null; then
            IP_METHOD="DİNAMİK (DHCP)"; IP_SOURCE="netplan"
        elif grep -rqE "addresses:" /etc/netplan/*.yaml 2>/dev/null; then
            IP_METHOD="STATİK"; IP_SOURCE="netplan"
        fi
    fi

    # Üsul 3: dhclient/systemd-networkd lease faylı axtarışı
    if [ -z "$IP_METHOD" ]; then
        if ls /var/lib/dhcp/*"$MAIN_IF"*.lease* >/dev/null 2>&1 || \
           ls /run/systemd/netif/leases/* >/dev/null 2>&1; then
            IP_METHOD="DİNAMİK (DHCP)"; IP_SOURCE="lease faylı tapıldı"
        fi
    fi

    # Üsul 4 (son çarə): "ip addr" çıxışında valid_lft forever varsa, adətən statikdir
    if [ -z "$IP_METHOD" ]; then
        LFT_LINE=$(ip -4 addr show "$MAIN_IF" | grep "valid_lft")
        if echo "$LFT_LINE" | grep -q "valid_lft forever"; then
            IP_METHOD="STATİK (ehtimal, valid_lft=forever əsasında)"; IP_SOURCE="ip addr çıxışı"
        elif [ -n "$LFT_LINE" ]; then
            IP_METHOD="DİNAMİK (ehtimal, DHCP lease vaxtı var)"; IP_SOURCE="ip addr çıxışı"
        else
            IP_METHOD="Naməlum"; IP_SOURCE="heç bir üsulla aşkarlanmadı"
        fi
    fi

    echo -e "${GREEN}IP tipi:${NC} $IP_METHOD  ${CYAN}(mənbə: $IP_SOURCE)${NC}"
fi

echo -e "${GREEN}DNS serverləri:${NC}"
resolvectl status 2>/dev/null | grep "DNS Server" | sed 's/^/  /' || cat /etc/resolv.conf | grep nameserver | sed 's/^/  /'

# ---------------------------------------------------
header "4. DOCKER MƏLUMATLARI"
if command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}Docker quraşdırılıb.${NC} Versiya: $(docker --version)"
    echo ""
    echo -e "${GREEN}İşləyən konteynerlər və portlar:${NC}"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
    echo ""
    RUNNING_COUNT=$(docker ps -q | wc -l)
    TOTAL_COUNT=$(docker ps -aq | wc -l)
    echo -e "${GREEN}İşləyən:${NC} $RUNNING_COUNT   ${GREEN}Cəmi (dayandırılmış daxil):${NC} $TOTAL_COUNT"
else
    echo "Docker quraşdırılmayıb."
fi

# ---------------------------------------------------
RED='\033[0;31m'
header "5. FIREWALL STATUSU"
if command -v ufw >/dev/null 2>&1; then
    UFW_RAW=$(ufw status 2>/dev/null | head -n1)
    if echo "$UFW_RAW" | grep -qi "inactive"; then
        echo -e "${GREEN}UFW:${NC} ${RED}DEAKTİV (söndürülüb)${NC}"
        echo -e "  Aktiv etmək üçün: sudo ufw enable"
    elif echo "$UFW_RAW" | grep -qi "active"; then
        echo -e "${GREEN}UFW:${NC} ${GREEN}AKTİV${NC}"
        echo ""
        echo -e "${GREEN}Qaydalar:${NC}"
        ufw status verbose 2>/dev/null | sed 's/^/  /'
    else
        echo -e "${GREEN}UFW:${NC} Status müəyyən edilə bilmədi (sudo ilə işlətməyi yoxlayın)"
    fi
elif command -v firewall-cmd >/dev/null 2>&1; then
    FW_STATE=$(firewall-cmd --state 2>/dev/null)
    if [ "$FW_STATE" = "running" ]; then
        echo -e "${GREEN}firewalld:${NC} ${GREEN}AKTİV${NC}"
    else
        echo -e "${GREEN}firewalld:${NC} ${RED}DEAKTİV${NC}"
    fi
else
    echo "UFW/firewalld tapılmadı. iptables qaydalarına baxılır:"
    iptables -L -n 2>/dev/null | head -n 15 | sed 's/^/  /'
fi

# ---------------------------------------------------
header "6. LSM (AppArmor / SELinux) STATUSU"
# Ubuntu/Debian-da SELinux əvəzinə AppArmor istifadə olunur
if command -v aa-status >/dev/null 2>&1; then
    if aa-status --enabled >/dev/null 2>&1; then
        echo -e "${GREEN}AppArmor:${NC} ${GREEN}AKTİV${NC}"
        echo ""
        aa-status 2>/dev/null | grep -E "profiles are (loaded|in enforce|in complain)" | sed 's/^/  /'
        echo ""
        echo -e "  Deaktiv etmək üçün: sudo systemctl stop apparmor && sudo systemctl disable apparmor"
    else
        echo -e "${GREEN}AppArmor:${NC} ${RED}DEAKTİV${NC}"
        echo -e "  Aktiv etmək üçün: sudo systemctl start apparmor && sudo systemctl enable apparmor"
    fi
elif command -v getenforce >/dev/null 2>&1; then
    SE_STATE=$(getenforce 2>/dev/null)
    if [ "$SE_STATE" = "Enforcing" ]; then
        echo -e "${GREEN}SELinux:${NC} ${GREEN}$SE_STATE (AKTİV)${NC}"
        echo -e "  Deaktiv etmək (müvəqqəti) üçün: sudo setenforce 0"
    else
        echo -e "${GREEN}SELinux:${NC} ${RED}$SE_STATE${NC}"
        echo -e "  Aktiv etmək (müvəqqəti) üçün: sudo setenforce 1"
    fi
    echo -e "  Daimi dəyişiklik üçün: /etc/selinux/config faylında SELINUX=enforcing və ya SELINUX=permissive yazın"
else
    echo "Nə AppArmor, nə də SELinux tapılmadı. Quraşdırmaq üçün: sudo apt install apparmor apparmor-utils"
fi

# ---------------------------------------------------
header "7. DİNLƏNƏN PORTLAR"
if command -v ss >/dev/null 2>&1; then
    printf "  %-6s %-28s %-20s %s\n" "PROTO" "ÜNVAN:PORT" "PROSES" "PID"
    printf "  %-6s %-28s %-20s %s\n" "-----" "----------" "------" "---"
    ss -tulpn 2>/dev/null | tail -n +2 | while IFS= read -r line; do
        proto=$(echo "$line" | awk '{print $1}')
        addr=$(echo "$line" | awk '{print $5}')
        proc=$(echo "$line" | sed -n 's/.*(("\([^"]*\)".*/\1/p')
        pid=$(echo "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
        [ -z "$proc" ] && proc="-"
        [ -z "$pid" ] && pid="-"
        printf "  %-6s %-28s %-20s %s\n" "$proto" "$addr" "$proc" "$pid"
    done
    echo ""
    echo -e "${CYAN}(Qeyd: 127.0.0.1 / 127.0.0.53 = yalnız lokal sistem daxilindən çıxışlıdır | 0.0.0.0 / [::] = xarici şəbəkədən əlçatandır)${NC}"
else
    echo "ss əmri tapılmadı. netstat yoxlanılır:"
    netstat -tulpn 2>/dev/null | sed 's/^/  /'
fi

# ---------------------------------------------------
header "8. HARDWARE / RESURS MƏLUMATI"

echo -e "${GREEN}RAM istifadəsi:${NC}"
free -h | sed 's/^/  /'

echo ""
echo -e "${GREEN}Disk sahəsi:${NC}"
df -h --output=source,size,used,avail,pcent,target 2>/dev/null | grep -Ev "tmpfs|udev|loop" | sed 's/^/  /'

echo ""
echo -e "${GREEN}CPU nüvə sayı:${NC} $(nproc)"

echo ""
echo -e "${GREEN}CPU məlumatı:${NC}"
lscpu | grep -E "^Model name|^CPU\(s\)|^Thread|^Core|^Socket|^CPU MHz|^Architecture" | sed 's/^/  /'

# ---------------------------------------------------
header "9. SİSTEM İSTİFADƏÇİLƏRİ"
echo -e "${GREEN}Login edə bilən (real) istifadəçilər:${NC}"
awk -F: '$3>=1000 && $1!="nobody" {print "  - " $1 " (UID:" $3 ", Shell:" $7 ")"}' /etc/passwd

echo ""
echo -e "${GREEN}Hazırda sistemə daxil olanlar:${NC}"
who

echo ""
line
echo -e "${YELLOW}Hesabat tamamlandı.${NC}"
echo -e "${YELLOW}Fayl saxlanıldı: ${CIXIS_FAYLI}${NC}"
line
