#!/bin/bash
set -euo pipefail

# ==============================================================================
# Интерактивный скрипт подготовки дисков + запуск CachyOS TUI-инсталлятора
# для конфигурации rEFInd + mdraid RAID1 (2 диска)
#
# Архитектура:
#   Фаза A — подготовка дисков (разметка, mdraid, mkfs, монтирование)
#   Фаза B — запуск CachyOS TUI-инсталлятора (pre_mounted_config)
#   Фаза C — донастройка rEFInd/ESP + memtest86+ внутри chroot
#   Фаза D — зеркалирование ESP + автохук синхронизации
#
# Запуск: из live-окружения CachyOS ISO (root, сеть поднята)
# ==============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_step() {
    echo -e "\n${GREEN}==> $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

# ==============================================================================
# fix_md_superblock_compat — обнуляет logical_block_size в суперблоках md 1.x
#   Аргументы: /dev/mdN:ВЕРСИЯ:/dev/член1:/dev/член2 (ВЕРСИЯ = 1.0 или 1.2)
#
# WHY: ядро >= 6.19 при создании массива пишет в суперблок поле logical_block_size
#   (байты 224..227, раньше часть pad3). Ядро <= 6.18 (LTS 6.18) видит ненулевой
#   pad3 и отвергает суперблок ("does not have a valid v1.x superblock"), а live-ISO
#   на 7.x создаёт массивы именно в таком виде — LTS их не соберёт.
#   Ядро 7.x при сборке выведет предупреждение про LBS — это ожидаемо.
#   Побочный эффект: защита от смены размера логического блока отключена; для дисков
#   512 Б смены не ожидается. Если поле уже 0 — Python-помощник пропускает члена.
#
# WHY udev-очередь остановлена: пока правим члены, udev по событию change вызвал бы
#   mdadm -I и пересобрал массив посреди записи. Очередь возвращается при любом исходе.
# ==============================================================================
fix_md_superblock_compat() {
    local rc=0 spec md ver member py_helper
    local -a fields members py_args=()

    py_helper=$(mktemp)
    cat > "$py_helper" << 'MDSB_PY_EOF'
#!/usr/bin/env python3
import os, struct, sys

MAGIC = 0xa92b4efc
CSUM_OFF = 216
MAXDEV_OFF = 220
LBS_OFF = 224          # logical_block_size (ядро >= 6.19), раньше pad3[0:4]
PAD_REST = (228, 256)  # остаток pad3: должен быть нулевым, иначе это неизвестная фича — не трогаем


def sb_offset(dev, ver):
    sectors = int(open('/sys/class/block/%s/size' % os.path.basename(dev)).read())
    if ver == '1.0':
        return ((sectors - 16) & ~7) * 512
    if ver == '1.2':
        return 8 * 512
    raise SystemExit('%s: неподдерживаемая версия метаданных %s' % (dev, ver))


def calc_csum(buf, max_dev):
    size = 256 + max_dev * 2
    total = 0
    for i in range(size // 4):
        if i * 4 == CSUM_OFF:
            continue
        total += struct.unpack_from('<I', buf, i * 4)[0]
    if size % 4 == 2:
        total += struct.unpack_from('<H', buf, (size // 4) * 4)[0]
    return ((total & 0xffffffff) + (total >> 32)) & 0xffffffff


def patch(dev, ver):
    off = sb_offset(dev, ver)
    fd = os.open(dev, os.O_RDWR | os.O_DSYNC)
    try:
        buf = bytearray(os.pread(fd, 4096, off))
        magic, major = struct.unpack_from('<II', buf, 0)
        if magic != MAGIC or major != 1:
            raise SystemExit('%s: не суперблок md 1.x по смещению %d' % (dev, off))
        max_dev = struct.unpack_from('<I', buf, MAXDEV_OFF)[0]
        if max_dev > 1920:
            raise SystemExit('%s: max_dev=%d вне допустимого' % (dev, max_dev))
        stored = struct.unpack_from('<I', buf, CSUM_OFF)[0]
        if calc_csum(buf, max_dev) != stored:
            raise SystemExit('%s: контрольная сумма не сходится ДО правки — не трогаю' % dev)
        if any(buf[PAD_REST[0]:PAD_REST[1]]) or struct.unpack_from('<I', buf, 12)[0]:
            raise SystemExit('%s: ненулевой pad вне logical_block_size — неизвестная фича, не трогаю' % dev)
        if struct.unpack_from('<I', buf, LBS_OFF)[0] == 0:
            print('%s: logical_block_size уже 0 — пропуск' % dev)
            return
        struct.pack_into('<I', buf, LBS_OFF, 0)
        struct.pack_into('<I', buf, CSUM_OFF, calc_csum(buf, max_dev))
        os.pwrite(fd, bytes(buf[:512]), off)
        os.fsync(fd)
        chk = bytearray(os.pread(fd, 4096, off))
        if struct.unpack_from('<I', chk, LBS_OFF)[0] != 0 or \
           calc_csum(chk, max_dev) != struct.unpack_from('<I', chk, CSUM_OFF)[0]:
            raise SystemExit('%s: проверка после записи не прошла' % dev)
        print('%s: logical_block_size обнулён, контрольная сумма пересчитана' % dev)
    finally:
        os.close(fd)


for spec in sys.argv[1:]:
    dev, ver = spec.split(':')
    patch(dev, ver)
MDSB_PY_EOF

    udevadm control --stop-exec-queue

    # WHY stop без udev: очередь уже остановлена, mdadm иначе ждёт udev и зависает.
    for spec in "$@"; do
        IFS=: read -r -a fields <<< "$spec"
        md=${fields[0]}
        if ! MDADM_NO_UDEV=1 mdadm --stop "$md"; then
            log_error "Не удалось остановить $md"
            rc=1
        fi
    done

    # WHY патч только при успешной остановке: правка члена активного массива
    # портит данные, которые ядро держит в памяти.
    if [[ $rc -eq 0 ]]; then
        for spec in "$@"; do
            IFS=: read -r -a fields <<< "$spec"
            ver=${fields[1]}
            for member in "${fields[@]:2}"; do
                py_args+=("$member:$ver")
            done
        done
        python3 "$py_helper" "${py_args[@]}" || rc=1
    fi

    # WHY пересборка всегда, даже при rc!=0: иначе скрипт оставит массивы остановленными.
    for spec in "$@"; do
        IFS=: read -r -a fields <<< "$spec"
        md=${fields[0]}
        members=("${fields[@]:2}")
        MDADM_NO_UDEV=1 mdadm --assemble "$md" "${members[@]}" || rc=1
    done

    udevadm control --start-exec-queue || rc=1
    udevadm settle || rc=1
    rm -f "$py_helper"

    if [[ $rc -ne 0 ]]; then
        log_error "fix_md_superblock_compat: сбой правки суперблоков или пересборки массивов"
        exit 1
    fi
}

# ==============================================================================
# Режимы работы (инвариант: оба запускаются по SSH)
#   Интерактив (дефолт): опрос + TUI фазы B. Нужен TTY (ssh -t; boot.sh
#     перецепляет stdin с pipe на /dev/tty).
#   --unattended --scenario FILE: ноль вопросов, фаза B через archinstall
#     --silent. Работает вообще без TTY — пригодно для автоматизации.
# Без TTY и без --unattended — fail fast, чтобы не висеть на read в трубе.
# ==============================================================================
MODE="interactive"
SCENARIO_FILE=""
LOG_FILE="/tmp/p510-install.log"
KERNEL_PKG="linux-cachyos"
SWAP_KERNEL=0

usage() {
    echo "Использование:"
    echo "  $0 [--unattended --scenario FILE] [--log FILE]"
    echo "Примеры:"
    echo "  $0                                        # интерактив, нужен TTY"
    echo "  $0 --unattended --scenario /tmp/stand.env  # сценарий, без вопросов"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unattended) MODE="unattended"; shift ;;
        --scenario) SCENARIO_FILE="${2:-}"; shift 2 ;;
        --log) LOG_FILE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "$MODE" == "unattended" && -z "$SCENARIO_FILE" ]]; then
    echo "--unattended требует --scenario FILE" >&2
    exit 1
fi

if [[ "$MODE" == "interactive" && ! -t 0 ]]; then
    echo "Интерактивному режиму нужен TTY (stdin — не терминал)." >&2
    echo "Варианты: запуск через boot.sh (перецепляет /dev/tty), ssh -t, или --unattended --scenario FILE." >&2
    exit 1
fi

# Лог всего прогона: в unattended по SSH это единственный способ понять падение.
exec > >(tee -a "$LOG_FILE") 2>&1
echo "==> Лог: $LOG_FILE | режим: $MODE"

# ==============================================================================
# Шаг 0: Проверка окружения
# ==============================================================================
log_step "Шаг 0: Проверка окружения"

if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт нужно запускать от root"
    exit 1
fi

# UEFI обязателен: rEFInd + efibootmgr без efivarfs не работают.
# Почему здесь, а не позже: разметка дисков разрушающая, нет смысла
# спрашивать 10 вопросов и затирать диски, чтобы потом упасть на efibootmgr.
if [[ ! -d /sys/firmware/efi ]]; then
    log_error "Система загружена не в UEFI-режиме (/sys/firmware/efi отсутствует)."
    echo "Перезагрузитесь с ISO в UEFI-режиме (без CSM/Legacy)."
    exit 1
fi

# Все внешние зависимости скрипта — одним проходом, до опроса переменных.
REQUIRED_TOOLS=(sgdisk mdadm rsync efibootmgr arch-chroot blkid wipefs partprobe udevadm python3)
MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done
if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    log_error "Отсутствуют зависимости: ${MISSING_TOOLS[*]}"
    echo "В live-окружении CachyOS: pacman -Sy gdisk mdadm rsync efibootmgr arch-install-scripts util-linux systemd python"
    exit 1
fi

# Сеть нужна Фазе B (инсталлятор тянет пакеты) и Фазе C (доустановка в chroot).
# Не фатально здесь: ISO мог поднять сеть позже, но предупредить надо до
# разрушающих действий, а не после разметки.
if ! getent hosts archlinux.org &> /dev/null; then
    log_warn "DNS не резолвится (getent hosts archlinux.org). Проверьте сеть перед Фазой B."
    read -rp "Сети нет. Продолжить всё равно? (yes/no) [no]: " NET_CONFIRM
    NET_CONFIRM=${NET_CONFIRM:-no}
    if [[ "$NET_CONFIRM" != "yes" ]]; then
        log_error "Остановлено: без сети установка невозможна"
        exit 1
    fi
fi

# ==============================================================================
# ФАЗА A — Подготовка дисков
# ==============================================================================

# ==============================================================================
# Шаг 1: Интерактивный опрос переменных
# ==============================================================================
log_step "Шаг 1: Параметры"

# Сценарий — обычный env-файл KEY=VALUE (см. scenario.example.env).
# Почему source, а не JSON+jq: на live-ISO гарантированно есть только bash,
# jq/python-зависимостей для парсинга не требуем. Значения со спецсимволами
# (пароли) — в одинарных кавычках, файл chmod 600, после использования shred.
load_scenario() {
    if [[ ! -f "$SCENARIO_FILE" ]]; then
        log_error "Файл сценария не найден: $SCENARIO_FILE"
        exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    source "$SCENARIO_FILE"
    set +a

    for var in DISK1 DISK2 HOSTNAME USERNAME USER_PASSWORD ROOT_PASSWORD; do
        if [[ -z "${!var:-}" ]]; then
            log_error "В сценарии нет обязательной переменной $var"
            exit 1
        fi
    done

    # Единственное подтверждение разрушения в unattended: человек, писавший
    # сценарий, явно разрешил снос. Без этого — стоп, никаких дефолтов.
    if [[ "${CONFIRM_DESTROY:-no}" != "yes" ]]; then
        log_error "Unattended требует CONFIRM_DESTROY=yes в сценарии"
        exit 1
    fi

    ESP_SIZE=${ESP_SIZE:-512MiB}
    BOOT_SIZE=${BOOT_SIZE:-1GiB}
    ROOT_SIZE=${ROOT_SIZE:-}
    ROOT_LABEL=${ROOT_LABEL:-cachy_root}
    BOOT_LABEL=${BOOT_LABEL:-cachy_boot}
    EXTRA_PKGS=${EXTRA_PKGS:-}
    TIMEZONE=${TIMEZONE:-UTC}
    LOCALE=${LOCALE:-en_US.UTF-8}
    KEYMAP=${KEYMAP:-us}
    KERNEL_PKG=${KERNEL_PKG:-linux-cachyos}
    # Доп. пакеты к ядру (headers, LTS, драйвер): ставятся фазой C вместе
    # со swap ядра. Пусто = только KERNEL_PKG.
    KERNEL_EXTRA_PKGS=${KERNEL_EXTRA_PKGS:-}
    # Метки ESP (FAT: до 11 символов). Shell пользователя в таргете.
    ESP_LABEL1=${ESP_LABEL1:-EFI-0}
    ESP_LABEL2=${ESP_LABEL2:-EFI-1}
    USER_SHELL=${USER_SHELL:-/bin/bash}

    if [[ "$DISK1" == "$DISK2" ]]; then
        log_error "Диски должны быть разными"
        exit 1
    fi
    for d in "$DISK1" "$DISK2"; do
        if [[ ! -b "/dev/$d" ]]; then
            log_error "Диск /dev/$d не существует"
            exit 1
        fi
    done
    if [[ ! "$ROOT_LABEL" =~ ^[A-Za-z0-9_-]{1,16}$ ]]; then
        log_error "Метка root '$ROOT_LABEL': только [A-Za-z0-9_-], длина 1-16"
        exit 1
    fi
    if [[ ! "$BOOT_LABEL" =~ ^[A-Za-z0-9_-]{1,16}$ ]]; then
        log_error "Метка /boot '$BOOT_LABEL': только [A-Za-z0-9_-], длина 1-16"
        exit 1
    fi
    if [[ ! "$HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
        log_error "Некорректный hostname: '$HOSTNAME'"
        exit 1
    fi
    if [[ ! "$KERNEL_PKG" =~ ^[a-z0-9+_.-]+$ ]]; then
        log_error "Некорректное имя пакета ядра: '$KERNEL_PKG'"
        exit 1
    fi
    for kp in $KERNEL_EXTRA_PKGS; do
        if [[ ! "$kp" =~ ^[a-z0-9+_.-]+$ ]]; then
            log_error "Некорректное имя пакета в KERNEL_EXTRA_PKGS: '$kp'"
            exit 1
        fi
    done
    if [[ ! "$ESP_LABEL1" =~ ^[A-Za-z0-9_-]{1,11}$ ]] || [[ ! "$ESP_LABEL2" =~ ^[A-Za-z0-9_-]{1,11}$ ]]; then
        log_error "Метки ESP '$ESP_LABEL1'/'$ESP_LABEL2': только [A-Za-z0-9_-], длина 1-11 (FAT)"
        exit 1
    fi
    if [[ ! "$USER_SHELL" =~ ^/(bin|usr/bin)/(bash|zsh|fish)$ ]]; then
        log_error "USER_SHELL '$USER_SHELL': только /bin/bash, /bin/zsh, /usr/bin/fish"
        exit 1
    fi

    echo "==> Сценарий $SCENARIO_FILE загружен и проверен"
    echo "    Диски: /dev/$DISK1 + /dev/$DISK2 | host: $HOSTNAME | user: $USERNAME ($USER_SHELL) | kernel: $KERNEL_PKG + [$KERNEL_EXTRA_PKGS]"
}

if [[ "$MODE" == "unattended" ]]; then
    echo "==> Режим unattended: параметры из сценария"
    load_scenario
else

echo "Доступные диски:"
lsblk -d -o NAME,SIZE,MODEL
echo

# Имена дисков
read -rp "Введите имя первого диска (например sda или nvme0n1): " DISK1
read -rp "Введите имя второго диска (например sdb или nvme1n1): " DISK2

if [[ -z "$DISK1" || -z "$DISK2" ]]; then
    log_error "Имена дисков не могут быть пустыми"
    exit 1
fi

if [[ "$DISK1" == "$DISK2" ]]; then
    log_error "Диски должны быть разными"
    exit 1
fi

if [[ ! -b "/dev/$DISK1" ]]; then
    log_error "Диск /dev/$DISK1 не существует"
    exit 1
fi

if [[ ! -b "/dev/$DISK2" ]]; then
    log_error "Диск /dev/$DISK2 не существует"
    exit 1
fi

# Размер ESP
read -rp "Размер ESP-раздела [512MiB]: " ESP_SIZE
ESP_SIZE=${ESP_SIZE:-512MiB}

# Размер /boot
read -rp "Размер раздела /boot [1GiB]: " BOOT_SIZE
BOOT_SIZE=${BOOT_SIZE:-1GiB}

# Размер / (пока не используется, весь остаток)
read -rp "Размер раздела / (пусто = весь остаток): " ROOT_SIZE
ROOT_SIZE=${ROOT_SIZE:-}

# Метки
read -rp "Метка root-тома [cachy_root]: " ROOT_LABEL
ROOT_LABEL=${ROOT_LABEL:-cachy_root}

read -rp "Метка /boot [cachy_boot]: " BOOT_LABEL
BOOT_LABEL=${BOOT_LABEL:-cachy_boot}

read -rp "Метка ESP на первом диске [EFI-0]: " ESP_LABEL1
ESP_LABEL1=${ESP_LABEL1:-EFI-0}

read -rp "Метка ESP на втором диске [EFI-1]: " ESP_LABEL2
ESP_LABEL2=${ESP_LABEL2:-EFI-1}

read -rp "Shell пользователя [/bin/bash]: " USER_SHELL
USER_SHELL=${USER_SHELL:-/bin/bash}

# Метки ext4 — макс. 16 символов, иначе mkfs обрежет молча и volume в
# refind.conf не совпадёт с реальной меткой (система не загрузится).
if [[ ! "$ROOT_LABEL" =~ ^[A-Za-z0-9_-]{1,16}$ ]]; then
    log_error "Метка root '$ROOT_LABEL': только [A-Za-z0-9_-], длина 1-16"
    exit 1
fi
if [[ ! "$BOOT_LABEL" =~ ^[A-Za-z0-9_-]{1,16}$ ]]; then
    log_error "Метка /boot '$BOOT_LABEL': только [A-Za-z0-9_-], длина 1-16"
    exit 1
fi
if [[ ! "$ESP_LABEL1" =~ ^[A-Za-z0-9_-]{1,11}$ ]] || [[ ! "$ESP_LABEL2" =~ ^[A-Za-z0-9_-]{1,11}$ ]]; then
    log_error "Метки ESP '$ESP_LABEL1'/'$ESP_LABEL2': только [A-Za-z0-9_-], длина 1-11 (FAT)"
    exit 1
fi
if [[ ! "$USER_SHELL" =~ ^/(bin|usr/bin)/(bash|zsh|fish)$ ]]; then
    log_error "USER_SHELL '$USER_SHELL': только /bin/bash, /bin/zsh, /usr/bin/fish"
    exit 1
fi

# Hostname
read -rp "Hostname будущей системы: " HOSTNAME
if [[ -z "$HOSTNAME" ]]; then
    log_error "Hostname не может быть пустым"
    exit 1
fi
if [[ ! "$HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
    log_error "Некорректный hostname: '$HOSTNAME'"
    exit 1
fi

# Дополнительные пакеты (справочно — archinstall TUI позволит выбрать свои)
read -rp "Доп. пакеты для заметки на память (архинсталл спросит сам, тут только справочно): " EXTRA_PKGS
EXTRA_PKGS=${EXTRA_PKGS:-}

fi  # конец ветки interactive (unattended брал всё из load_scenario выше)

# ==============================================================================
# Шаг 2: Формирование и отображение плана разметки
# ==============================================================================
log_step "Шаг 2: План разметки"

echo "
План разметки:
  Диск 1: /dev/$DISK1
  Диск 2: /dev/$DISK2

  Разделы на каждом диске:
    1. ESP ($ESP_SIZE, ef00, FAT32)
    2. /boot ($BOOT_SIZE, fd00, ext4, член /dev/md0, RAID1 metadata=1.0)
    3. / (весь остаток, fd00, ext4, член /dev/md1, RAID1 metadata=1.2)

  Метки:
    /boot: $BOOT_LABEL
    /:     $ROOT_LABEL
    ESP1:  $ESP_LABEL1
    ESP2:  $ESP_LABEL2

  Hostname: $HOSTNAME

  Доп. пакеты: ${EXTRA_PKGS:-нет}

  Установка: CachyOS TUI-инсталлятор (pre_mounted_config)
  После инсталлятора: донастройка rEFInd/ESP (chroot)
"

# ==============================================================================
# Шаг 3: Подтверждение перед разрушающими действиями
# ==============================================================================
if [[ "$MODE" == "unattended" ]]; then
    # Подтверждением служит CONFIRM_DESTROY=yes в сценарии (проверен в load_scenario).
    echo "==> Unattended: подтверждение сноса — CONFIRM_DESTROY=yes из сценария"
else
    log_warn "ВНИМАНИЕ: Все данные на дисках /dev/$DISK1 и /dev/$DISK2 будут УНИЧТОЖЕНЫ!"
    read -rp "Продолжить? (yes/no) [no]: " CONFIRM
    CONFIRM=${CONFIRM:-no}

    if [[ "$CONFIRM" != "yes" ]]; then
        log_error "Установка отменена пользователем"
        exit 1
    fi
fi

# ==============================================================================
# Шаг 4: Разметка дисков
# ==============================================================================
log_step "Шаг 4: Разметка дисков"

# Формат размеров для sgdisk -n: число + единица. Проверяем до разрушения дисков.
if [[ ! "$ESP_SIZE" =~ ^[0-9]+(MiB|GiB)$ ]]; then
    log_error "Некорректный размер ESP: '$ESP_SIZE' (пример: 512MiB)"
    exit 1
fi
if [[ ! "$BOOT_SIZE" =~ ^[0-9]+(MiB|GiB)$ ]]; then
    log_error "Некорректный размер /boot: '$BOOT_SIZE' (пример: 1GiB)"
    exit 1
fi
if [[ -n "$ROOT_SIZE" && ! "$ROOT_SIZE" =~ ^[0-9]+(MiB|GiB)$ ]]; then
    log_error "Некорректный размер /: '$ROOT_SIZE' (пример: 50GiB, пусто = остаток)"
    exit 1
fi

# Стопим зависшие массивы ДО zap: иначе ядро держит разделы открытыми
# и sgdisk/wipefs получат EBUSY на занятых устройствах.
for stale_md in /dev/md0 /dev/md1; do
    if [[ -b "$stale_md" ]]; then
        log_warn "Останавливаю зависший массив $stale_md перед разметкой"
        mdadm --stop "$stale_md" || true
    fi
done

# Очистка и разметка первого диска
echo "==> Разметка /dev/$DISK1"
sgdisk --zap-all "/dev/$DISK1"
sgdisk -n1:0:+"${ESP_SIZE}" -t1:ef00 -c1:"EFI-${DISK1}" "/dev/$DISK1"
sgdisk -n2:0:+"${BOOT_SIZE}" -t2:fd00 -c2:"BOOT-${DISK1}" "/dev/$DISK1"
if [[ -n "$ROOT_SIZE" ]]; then
    sgdisk -n3:0:+"${ROOT_SIZE}" -t3:fd00 -c3:"ROOT-${DISK1}" "/dev/$DISK1"
else
    sgdisk -n3:0:0 -t3:fd00 -c3:"ROOT-${DISK1}" "/dev/$DISK1"
fi

# Очистка и разметка второго диска
echo "==> Разметка /dev/$DISK2"
sgdisk --zap-all "/dev/$DISK2"
sgdisk -n1:0:+"${ESP_SIZE}" -t1:ef00 -c1:"EFI-${DISK2}" "/dev/$DISK2"
sgdisk -n2:0:+"${BOOT_SIZE}" -t2:fd00 -c2:"BOOT-${DISK2}" "/dev/$DISK2"
if [[ -n "$ROOT_SIZE" ]]; then
    sgdisk -n3:0:+"${ROOT_SIZE}" -t3:fd00 -c3:"ROOT-${DISK2}" "/dev/$DISK2"
else
    sgdisk -n3:0:0 -t3:fd00 -c3:"ROOT-${DISK2}" "/dev/$DISK2"
fi

# Определение имён разделов (работает для sda/sdb и nvme0n1/nvme1n1)
if [[ "$DISK1" =~ [0-9]$ ]]; then
    # NVMe: nvme0n1 -> nvme0n1p1, nvme0n1p2, nvme0n1p3
    PART1_1="${DISK1}p1"
    PART1_2="${DISK1}p2"
    PART1_3="${DISK1}p3"
    PART2_1="${DISK2}p1"
    PART2_2="${DISK2}p2"
    PART2_3="${DISK2}p3"
else
    # SATA/SCSI: sda -> sda1, sda2, sda3
    PART1_1="${DISK1}1"
    PART1_2="${DISK1}2"
    PART1_3="${DISK1}3"
    PART2_1="${DISK2}1"
    PART2_2="${DISK2}2"
    PART2_3="${DISK2}3"
fi

# sgdisk --zap-all сносит GPT, но НЕ трогает md-суперблоки на разделах
# (metadata 1.0 живёт в конце устройства, 1.2 — со сдвигом 4K — оба переживают
# пересоздание таблицы). Без зачистки mdadm --create упрётся в
# "appears to be part of an array" именно на повторном прогоне скрипта.
# Плюс гонка: udev инкрементально пересобирает массивы из свежих разделов
# (смещения те же, суперблоки ещё на месте) раньше, чем мы дойдём до wipefs.
# Поэтому перед зачисткой — повторный стоп всего, что успело пересобраться.
# Сначала перечитать таблицы: без partprobe свежих узлов /dev/sdX3 может
# вообще не быть (ядро держит старую таблицу) — wipefs падает «No such file»,
# а при set -e это смерть прогона.
# Побочка partprobe: udev тут же пересобирает массивы из старых суперблоков
# (смещения разделов те же) — поэтому сразу за ним повторный стоп.
partprobe "/dev/$DISK1" "/dev/$DISK2"
udevadm settle
for reassembled_md in /dev/md0 /dev/md1; do
    if [[ -b "$reassembled_md" ]]; then
        log_warn "udev пересобрал $reassembled_md из свежих разделов — останавливаю"
        mdadm --stop "$reassembled_md" || true
    fi
done
echo "==> Зачистка сигнатур на новых разделах"
wipefs -a "/dev/$PART1_1" "/dev/$PART1_2" "/dev/$PART1_3" \
         "/dev/$PART2_1" "/dev/$PART2_2" "/dev/$PART2_3"
mdadm --zero-superblock "/dev/$PART1_2" "/dev/$PART1_3" \
                       "/dev/$PART2_2" "/dev/$PART2_3" 2>/dev/null || true

# Суперблоки затёрты выше — пересобраться массивам не из чего.
# Финальный settle перед --create (таблицы уже перечитаны, узлы на месте).
udevadm settle
echo "==> Таблицы разделов перечитаны — OK"

# ==============================================================================
# Шаг 5: Создание RAID-массивов
# ==============================================================================
log_step "Шаг 5: Создание RAID-массивов"

# Проверка, не существуют ли уже массивы
# В unattended без TTY read вернёт EOF и упадёт в exit — поэтому при
# CONFIRM_DESTROY=yes останавливаем молча: снос уже разрешён сценарием.
if [[ -b /dev/md0 ]]; then
    if [[ "$MODE" == "unattended" ]]; then
        log_warn "Unattended: останавливаю существующий /dev/md0 без спроса"
        mdadm --stop /dev/md0 || true
    else
        log_warn "Устройство /dev/md0 уже существует!"
        read -rp "Пересоздать? (yes/no) [no]: " RECREATE_MD0
        RECREATE_MD0=${RECREATE_MD0:-no}
        if [[ "$RECREATE_MD0" == "yes" ]]; then
            mdadm --stop /dev/md0 || true
        else
            log_error "Невозможно продолжить с существующим /dev/md0"
            exit 1
        fi
    fi
fi

if [[ -b /dev/md1 ]]; then
    if [[ "$MODE" == "unattended" ]]; then
        log_warn "Unattended: останавливаю существующий /dev/md1 без спроса"
        mdadm --stop /dev/md1 || true
    else
        log_warn "Устройство /dev/md1 уже существует!"
        read -rp "Пересоздать? (yes/no) [no]: " RECREATE_MD1
        RECREATE_MD1=${RECREATE_MD1:-no}
        if [[ "$RECREATE_MD1" == "yes" ]]; then
            mdadm --stop /dev/md1 || true
        else
            log_error "Невозможно продолжить с существующим /dev/md1"
            exit 1
        fi
    fi
fi

# /boot — metadata 1.0 обязательно, иначе rEFInd/UEFI не прочитает ФС напрямую
# --run: не спрашивать подтверждение, массивы нужны сразу для mkfs.
echo "==> Создание /dev/md0 (boot, metadata=1.0)"
mdadm --create /dev/md0 --run --level=1 --raid-devices=2 \
      --metadata=1.0 "/dev/$PART1_2" "/dev/$PART2_2"

# / — обычный 1.2
echo "==> Создание /dev/md1 (root, metadata=1.2)"
mdadm --create /dev/md1 --run --level=1 --raid-devices=2 \
      --metadata=1.2 "/dev/$PART1_3" "/dev/$PART2_3"

# WHY сразу после create, до mkfs: иначе LTS-ядро не соберёт массивы при загрузке.
fix_md_superblock_compat "/dev/md0:1.0:/dev/$PART1_2:/dev/$PART2_2" "/dev/md1:1.2:/dev/$PART1_3:/dev/$PART2_3"

udevadm settle
for md in /dev/md0 /dev/md1; do
    if [[ ! -b "$md" ]]; then
        log_error "Массив $md не появился после --create"
        exit 1
    fi
done

echo "==> Проверка массивов:"
cat /proc/mdstat
mdadm --detail /dev/md0
mdadm --detail /dev/md1

# ==============================================================================
# Шаг 6: Создание файловых систем
# ==============================================================================
log_step "Шаг 6: Создание файловых систем"

echo "==> Создание ext4 на /dev/md0 (boot)"
mkfs.ext4 -L "$BOOT_LABEL" /dev/md0

echo "==> Создание ext4 на /dev/md1 (root)"
mkfs.ext4 -L "$ROOT_LABEL" /dev/md1

echo "==> Создание FAT32 на ESP"
mkfs.fat -F32 -n "$ESP_LABEL1" "/dev/$PART1_1"
mkfs.fat -F32 -n "$ESP_LABEL2" "/dev/$PART2_1"

# ==============================================================================
# Шаг 7: Монтирование
# ==============================================================================
log_step "Шаг 7: Монтирование"

mount /dev/md1 /mnt
mkdir -p /mnt/boot
mount /dev/md0 /mnt/boot
# NB: /mnt/boot/efi создавать только ПОСЛЕ монтирования md0: маунт затеняет
# всё, что было создано в /mnt/boot до него (баг: mount point does not exist).
mkdir -p /mnt/boot/efi
mount "/dev/$PART1_1" /mnt/boot/efi

# ==============================================================================
# ФАЗА B — Запуск CachyOS TUI-инсталлятора
# ==============================================================================

# ==============================================================================
# Шаг 8: Проверка наличия инсталлятора
# ==============================================================================
log_step "Шаг 8: Поиск инсталлятора"

# Порядок: нативные CachyOS-инсталляторы первыми, чистый archinstall — запасной.
# Почему только command -v без запуска --help: TUI-инсталляторы на --help могут
# открыть интерфейс вместо печати help и подвесить скрипт. Детект — только по
# наличию бинарника, никаких пробных запусков.
INSTALLER=""
for candidate in cachyos-installer cachyos-install archinstall; do
    if command -v "$candidate" &> /dev/null; then
        INSTALLER="$candidate"
        break
    fi
done

if [[ -z "$INSTALLER" ]]; then
    log_error "Инсталлятор не найден (искал: cachyos-installer, cachyos-install, archinstall)!"
    echo "Проверьте вручную:"
    echo "  which cachyos-installer cachyos-install archinstall"
    echo "  pacman -Qs cachyos-cli-installer"
    echo "Возможно, live-ISO не является CachyOS, или инсталлятор называется иначе."
    exit 1
fi

log_step "Найден инсталлятор: $INSTALLER"

# ==============================================================================
# Шаг 9: Значение bootloader для конфига (предзаполнение, не догма)
# ==============================================================================
log_step "Шаг 9: Предзаполнение bootloader"

# Сознательно НЕ детектим enum через --list-bootloaders / python-import / --help:
# флага --list-bootloaders у archinstall нет, путь Python-модуля меняется между
# версиями, а --help у TUI может подвесить скрипт. Все три способа — хрупкие.
# Конфиг ниже — только предзаполнение: инсталлятор запускается НЕ в --silent,
# пользователь видит значение в TUI и правит руками. Безопасный дефолт — Refind:
# он есть во всех версиях archinstall, а Фаза C всё равно переустановит/дополнит
# rEFInd нужными файлами. Если в TUI доступен вариант без загрузчика — выбрать его.
BOOTLOADER_VALUE="Refind"
echo "==> Предзаполнение bootloader: '$BOOTLOADER_VALUE' (проверьте в TUI вручную)"

# ==============================================================================
# Шаг 10: Генерация JSON-конфига для archinstall
# ==============================================================================
log_step "Шаг 10: Генерация JSON-конфига archinstall"

ARCHINSTALL_CONFIG="/tmp/archinstall-disk-config.json"
INSTALL_KERNEL="$KERNEL_PKG"

# Проверяем, знает ли archinstall на этом ISO запрошенное ядро как допустимое
# значение kernels (ванильный enum: linux, linux-lts, zen... — linux-cachyos
# там есть только если сборка CachyOS пропатчила archinstall).
# Способ: ищем имя пакета в исходниках установленного archinstall — грубый,
# но не зависит от пути Python-модуля, который плавает между версиями.
probe_kernel_pkg() {
    local pkgdir
    pkgdir=$(python3 -c "import archinstall, os; print(os.path.dirname(archinstall.__file__))" 2>/dev/null) || return 1
    grep -rq -- "$KERNEL_PKG" "$pkgdir" 2>/dev/null
}

if [[ "$MODE" == "unattended" ]]; then
    if ! command -v archinstall &> /dev/null; then
        log_error "Unattended-режиму нужен бинарник archinstall (batch через --silent)."
        echo "На этом ISO есть только '$INSTALLER'. Либо ставьте через TUI (интерактив),"
        echo "либо используйте ISO с archinstall."
        exit 1
    fi
    if [[ "$KERNEL_PKG" != "linux" ]] && ! probe_kernel_pkg; then
        log_warn "archinstall не знает ядро '$KERNEL_PKG' — ставлю ванильный linux,"
        log_warn "Фаза C заменит его на '$KERNEL_PKG' (SWAP_KERNEL=1)"
        INSTALL_KERNEL="linux"
        SWAP_KERNEL=1
    else
        echo "==> Ядро '$KERNEL_PKG' поддерживается конфигом — ставим сразу"
    fi
fi

# Схема silent-конфига: загрузчика от archinstall НЕТ вообще.
# Почему: add_bootloader в archinstall 4.5 не детектит root на pre-mounted
# mdraid (ValueError «Could not detect root at mountpoint /mnt», guided.py
# вызывает add_bootloader всегда, когда bootloader != NO_BOOTLOADER).
# Поэтому unattended ставит «No bootloader» + флаг --skip-boot, а rEFInd
# целиком делает Фаза C (C.4 refind-install, C.5 драйвер, C.7 refind.conf).
# Оба ключа (bootloader_config + устаревший bootloader) — со значением
# «No bootloader»: свежий читает subdict (args.py: приоритет), старому
# top-level нужен как фолбэк. Интерактивная ветка ниже — отдельно, там
# предзаполнение Refind для ручного выбора в TUI.
#
# Остальные ключи silent-конфига — только с известной формой (man archinstall 2.6.0):
# disk_config, hostname, kernels, packages, locale_config {kb_layout, sys_enc,
# sys_lang}, timezone (строка). Сеть, пользователи, sudoers, NetworkManager —
# детерминированно делает Фаза C (блок C.9), а не угадывание схемы creds.
if [[ "$MODE" == "unattended" ]]; then
    SYS_LANG=${LOCALE%%.*}
    PKG_LIST=(base base-devel "$INSTALL_KERNEL" mdadm efibootmgr refind vim networkmanager rsync gdisk dosfstools)
    if [[ -n "$EXTRA_PKGS" ]]; then
        # shellcheck disable=SC2206
        PKG_LIST+=($EXTRA_PKGS)
    fi
    PKGS_JSON=$(printf '"%s",' "${PKG_LIST[@]}")
    PKGS_JSON="[${PKGS_JSON%,}]"

    cat > "$ARCHINSTALL_CONFIG" << CONFEOF
{
    "disk_config": {
        "config_type": "pre_mounted_config",
        "mountpoint": "/mnt"
    },
    "bootloader_config": {
        "bootloader": "No bootloader"
    },
    "bootloader": "No bootloader",
    "hostname": "$HOSTNAME",
    "kernels": ["$INSTALL_KERNEL"],
    "packages": $PKGS_JSON,
    "locale_config": {
        "kb_layout": "$KEYMAP",
        "sys_enc": "UTF-8",
        "sys_lang": "$SYS_LANG"
    },
    "timezone": "$TIMEZONE"
}
CONFEOF
else
    cat > "$ARCHINSTALL_CONFIG" << CONFEOF
{
    "disk_config": {
        "config_type": "pre_mounted_config",
        "mountpoint": "/mnt"
    },
    "bootloader_config": {
        "bootloader": "$BOOTLOADER_VALUE"
    },
    "bootloader": "$BOOTLOADER_VALUE",
    "hostname": "$HOSTNAME"
}
CONFEOF
fi

echo "==> Конфиг сохранён: $ARCHINSTALL_CONFIG"
echo "--- Содержимое ---"
cat "$ARCHINSTALL_CONFIG"
echo "--- конец ---"

# ==============================================================================
# Шаг 11: Запуск инсталлятора
# ==============================================================================
if [[ "$MODE" == "unattended" ]]; then
    log_step "Шаг 11: Запуск archinstall --silent"

    ARCHINSTALL_LOG="/tmp/archinstall-silent.log"
    # --skip-ntp/--skip-wkd обязательны: archinstall бесконечно ждёт NTP-синхры
    # и archlinux-keyring-wkd-sync.service БЕЗ таймаута (_verify_service_stop),
    # а wkd-таймера на CachyOS ISO вообще нет → silent виснет навсегда.
    echo "==> archinstall --config $ARCHINSTALL_CONFIG --silent --skip-ntp --skip-wkd --skip-boot (лог: $ARCHINSTALL_LOG)"
    if archinstall --config "$ARCHINSTALL_CONFIG" --silent --skip-ntp --skip-wkd --skip-boot >"$ARCHINSTALL_LOG" 2>&1; then
        echo "==> Silent-установка завершена успешно"
    else
        INSTALLER_EXIT=$?
        log_error "archinstall --silent упал (код $INSTALLER_EXIT). Хвост лога:"
        tail -n 50 "$ARCHINSTALL_LOG"
        # Откат на TUI — только если вообще есть с кем разговаривать.
        # Без TTY (автоматизация) — жёсткий выход с кодом ошибки.
        if [[ -t 0 ]]; then
            read -rp "Открыть TUI вручную для добивки? (yes/no) [no]: " BARE_CONFIRM
            BARE_CONFIRM=${BARE_CONFIRM:-no}
            if [[ "$BARE_CONFIRM" == "yes" ]]; then
                archinstall --config "$ARCHINSTALL_CONFIG" || true
            else
                exit $INSTALLER_EXIT
            fi
        else
            exit $INSTALLER_EXIT
        fi
    fi
else
log_step "Шаг 11: Запуск CachyOS TUI-инсталлятора"

echo "Инсталлятор запустится в режиме pre_mounted_config."
echo "Разметка НЕ будет затронута — инсталлятор берёт то, что уже смонтировано под /mnt."
echo "Вы сможете интерактивно выбрать: локаль, пользователей, сеть, доп. пакеты."
echo
read -rp "Открыть инсталлятор с этим конфигом? (yes/no) [no]: " LAUNCH_CONFIRM
LAUNCH_CONFIRM=${LAUNCH_CONFIRM:-no}

if [[ "$LAUNCH_CONFIRM" != "yes" ]]; then
    log_error "Установка отменена пользователем"
    exit 1
fi

# Запуск без --silent: пользователь докручивает TUI-интерфейс.
# Нюанс: C++ TUI (cachyos-install) может не понимать --config вообще — тогда
# пробуем голый запуск, чтобы не упираться в usage-error вместо установки.
if $INSTALLER --config "$ARCHINSTALL_CONFIG"; then
    echo "==> Инсталлятор завершён успешно"
else
    INSTALLER_EXIT=$?
    log_warn "Инсталлятор завершился с кодом $INSTALLER_EXIT"
    echo "Это может быть нормально (пользователь вышел вручную), ошибкой,"
    echo "или признаком что '$INSTALLER' не понимает --config."
    read -rp "Запустить '$INSTALLER' без конфига (голый TUI)? (yes/no) [no]: " BARE_CONFIRM
    BARE_CONFIRM=${BARE_CONFIRM:-no}
    if [[ "$BARE_CONFIRM" == "yes" ]]; then
        echo "==> Голый запуск: в TUI выберите pre-mounted / существующие разделы вручную,"
        echo "    загрузчик '$BOOTLOADER_VALUE' (или без загрузчика — Фаза C донастроит rEFInd сама)."
        if $INSTALLER; then
            echo "==> Инсталлятор завершён успешно"
        else
            log_warn "Голый запуск завершился с кодом $?"
        fi
    fi
fi  # конец if $INSTALLER --config
fi  # конец ветки interactive шага 11 (if MODE)

# ==============================================================================
# Шаг 12: Проверка после инсталлятора
# ==============================================================================
log_step "Шаг 12: Проверка после инсталлятора"

# Проверяем что /mnt всё ещё смонтирован — по уровням, а не одним махом:
# инсталлятор может сбросить один уровень (обычно /boot/efi), а mount /dev/md1
# поверх уже смонтированного /mnt даст EBUSY. Поэтому каждый уровень — отдельно.
if ! mountpoint -q /mnt; then
    echo "==> Перемонтирую /mnt"
    mount /dev/md1 /mnt
fi
mkdir -p /mnt/boot /mnt/boot/efi
if ! mountpoint -q /mnt/boot; then
    echo "==> Перемонтирую /mnt/boot"
    mount /dev/md0 /mnt/boot
fi
if ! mountpoint -q /mnt/boot/efi; then
    log_warn "/mnt/boot/efi не смонтирован! Инсталлятор мог размонтировать разделы."
    echo "Попытка перемонтировать..."
    mount "/dev/$PART1_1" /mnt/boot/efi
    echo "==> Разделы перемонтированы"
else
    echo "==> /mnt/boot/efi смонтирован — OK"
fi

# Проверяем что в /mnt есть базовая система
if [[ ! -d /mnt/etc ]] || [[ ! -f /mnt/etc/fstab ]]; then
    log_error "В /mnt не обнаружена установка системы (/etc или fstab отсутствуют)"
    echo "Инсталлятор мог не завершить установку. Проверьте вручную."
    exit 1
fi

echo "==> Базовая система установлена — OK"

# ==============================================================================
# ФАЗА C — Донастройка rEFInd/ESP внутри chroot
# ==============================================================================

# ==============================================================================
# Шаг 13: chroot — донастройка системы
# ==============================================================================
log_step "Шаг 13: Фаза C — донастройка rEFInd/ESP + memtest86+ (chroot)"

# Копируем скрипт для chroot
# NB: кладём в /root, НЕ в /tmp: современный arch-chroot монтирует tmpfs
# поверх $chroot/tmp (chroot_setup() в arch-install-scripts) — всё, что лежит
# в /mnt/tmp, внутри chroot невидимо (прогон 6 упал с ENOENT именно на этом).
mkdir -p /mnt/root
cat > /mnt/root/chroot-setup.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail

echo "==> [Фаза C] Донастройка rEFInd/ESP"

# ------------------------------------------------------------------
# C.0: Гарантировать пакеты в таргете (TUI мог их не выбрать)
#       Без mdadm система не соберёт RAID на загрузке = unbootable.
#       --needed: не переустанавливать то что уже есть.
# ------------------------------------------------------------------
# C.0a: Репа CachyOS в таргете — нужна C.2b для linux-cachyos.
#       archinstall мог не перенести [cachyos] из live-окружения в таргет,
#       проверяем явно: без репы swap ядра упадёт «target not found».
#       pacman-key --populate идемпотентен, повторный прогон безопасен.
echo "==> C.0a: Проверка репы [cachyos] в таргете"
if [[ ! -f /etc/pacman.d/cachyos-mirrorlist ]]; then
    echo "    mirrorlist нет — ставлю cachyos-mirrorlist"
    pacman -S --noconfirm --needed cachyos-mirrorlist
fi
if ! grep -q '^\[cachyos\]' /etc/pacman.conf; then
    echo "    секции [cachyos] нет — дописываю в pacman.conf"
    printf '\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' >> /etc/pacman.conf
fi
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinux cachyos
pacman -Sy

# CachyOS заменяет zlib на zlib-ng-compat (в их репозитории Replaces: zlib, для lib32 то же),
# и пакеты репозитория (wine-cachyos, proton-cachyos, steam-обвязка) собраны под него.
# archinstall ставит базу с zlib из core; при pacman -S без полного апгрейда «замены» не
# срабатывают, а на вопрос о конфликте при --noconfirm по умолчанию «нет» — игровой набор
# падал с "zlib-ng-compat and zlib are in conflict". Меняем явно: --ask 4 = «да» на
# удаление конфликтующего пакета (поставщик libz.so остаётся — zlib-ng-compat provides zlib).
echo "==> C.0a: zlib -> zlib-ng-compat (как в штатной CachyOS)"
pacman -S --noconfirm --ask 4 --needed zlib-ng-compat lib32-zlib-ng-compat

echo "==> C.0: Доустановка пакетов в таргет"
pacman -S --noconfirm --needed mdadm refind rsync efibootmgr gdisk dosfstools

# ------------------------------------------------------------------
# C.1: Перезаписать /etc/mdadm.conf (архинсталл мог написать некорректно
#       из-за "too complicated to detect" для RAID)
#       HOMEHOST <ignore> первой строкой: массивы созданы в live-окружении с его
#       hostname, а в initramfs и установленной системе hostname другой. Без
#       этой строки udev считает массивы чужими, root по UUID не находится и
#       загрузка падает в emergency shell. Файл перезаписывается целиком, поэтому
#       повторный запуск не плодит дубли ARRAY-строк.
#       MAILADDR root: без MAILADDR или PROGRAM mdmonitor при каждой загрузке падает
#       с "No mail address or alert command - not monitoring" и висит в systemctl --failed.
# ------------------------------------------------------------------
echo "==> C.1: Перезапись /etc/mdadm.conf"
{
    echo "HOMEHOST <ignore>"
    echo "MAILADDR root"
    mdadm --detail --scan
} > /etc/mdadm.conf

# ------------------------------------------------------------------
# C.2: Проверить/добавить mdadm_udev и mdrun в HOOKS mkinitcpio.conf
#       Идемпотентно: каждое слово ищем именно в строке HOOKS (не во всём файле),
#       иначе совпадение в комментарии сочтём за «уже добавлено».
#       Итог: block mdadm_udev mdrun filesystems — mdrun обязан идти после udev.
# ------------------------------------------------------------------
echo "==> C.2: Проверка mdadm_udev в HOOKS"
if ! grep '^HOOKS=' /etc/mkinitcpio.conf | grep -qw mdadm_udev; then
    sed -i 's/^HOOKS=(\(.*\)filesystems/HOOKS=(\1 mdadm_udev filesystems/' /etc/mkinitcpio.conf
    echo "    mdadm_udev добавлен в HOOKS"
else
    echo "    mdadm_udev уже есть в HOOKS — OK"
fi

# ------------------------------------------------------------------
# C.2a: Свой initcpio-хук mdrun — запуск degraded-массивов при загрузке
#       mdadm_udev собирает массив только когда пришли ВСЕ члены. При мёртвом
#       или отключённом диске RAID1 остаётся inactive, и root не находится —
#       ради этого зеркало и затевалось. Хук ставим после udev, чтобы он видел
#       уже собранные полным набором массивы.
# ------------------------------------------------------------------
echo "==> C.2a: Установка хука mdrun"
mkdir -p /etc/initcpio/install /etc/initcpio/hooks

cat > /etc/initcpio/install/mdrun << 'MDRUN_INSTALL_EOF'
#!/bin/bash
build() {
    add_binary mdadm
    add_runscript
}
help() {
    echo "Запускает неполностью собранные (degraded) md-массивы, оставленные udev в inactive."
}
MDRUN_INSTALL_EOF
chmod 755 /etc/initcpio/install/mdrun

cat > /etc/initcpio/hooks/mdrun << 'MDRUN_HOOK_EOF'
#!/usr/bin/ash
run_hook() {
    # run_hook идёт после udev-хука: тот уже сделал udevadm settle, массивы
    # с полным набором членов уже active. Ждём до 5 с только если есть inactive:
    # второй диск может подняться чуть позже, и форсировать degraded раньше
    # времени значило бы получить лишний ресинк.
    i=0
    while [ "$i" -lt 5 ]; do
        need=0
        for md in /sys/block/md*; do
            [ -r "$md/md/array_state" ] || continue
            read -r state < "$md/md/array_state"
            [ "$state" = "inactive" ] && need=1
        done
        [ "$need" -eq 0 ] && return 0
        sleep 1
        i=$((i + 1))
    done
    for md in /sys/block/md*; do
        [ -r "$md/md/array_state" ] || continue
        read -r state < "$md/md/array_state"
        if [ "$state" = "inactive" ]; then
            msg ":: mdrun: запуск degraded-массива ${md##*/}"
            mdadm --run "/dev/${md##*/}" || true
        fi
    done
    udevadm settle
}
MDRUN_HOOK_EOF
chmod 755 /etc/initcpio/hooks/mdrun

# mdrun — отдельной проверкой и вставкой перед filesystems, после mdadm_udev
if ! grep '^HOOKS=' /etc/mkinitcpio.conf | grep -qw mdrun; then
    sed -i 's/^HOOKS=(\(.*\)filesystems/HOOKS=(\1 mdrun filesystems/' /etc/mkinitcpio.conf
    echo "    mdrun добавлен в HOOKS"
else
    echo "    mdrun уже есть в HOOKS — OK"
fi

# ------------------------------------------------------------------
# C.2b: Откатное ядро — silent-конфиг мог поставить ванильный linux,
#        т.к. enum archinstall не знает linux-cachyos (см. probe_kernel_pkg).
#        Ставим запрошенное, проверяем образ, только потом сносим ваниль.
#        В интерактиве SWAP всегда 0 — блок молча пропускается.
# ------------------------------------------------------------------
if [[ "SWAP_KERNEL_PLACEHOLDER" == "1" ]]; then
    echo "==> C.2b: Замена ядра linux -> KERNEL_PKG_PLACEHOLDER"
    pacman -S --noconfirm --needed KERNEL_PKG_PLACEHOLDER
    if [[ -f /boot/vmlinuz-KERNEL_PKG_PLACEHOLDER ]]; then
        pacman -R --noconfirm linux || true
    else
        echo "    ОШИБКА: образ /boot/vmlinuz-KERNEL_PKG_PLACEHOLDER не появился" >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------
# C.2b-extra: Доп. пакеты к ядру из сценария (headers, LTS-ядро, драйвер).
#       Независимо от SWAP: нужны и когда archinstall знал KERNEL_PKG
#       (SWAP=0, ядро уже в таргете), и когда нет. Пустой список — пропуск.
#       NB: nvidia-модуль держим здесь, а не в EXTRA_PKGS фазы B: он зависит
#       от linux-cachyos=X.Y-Z, которого в фазе B ещё нет.
# ------------------------------------------------------------------
if [[ -n "KERNEL_EXTRA_PKGS_PLACEHOLDER" ]]; then
    echo "==> C.2b-extra: Доустановка: KERNEL_EXTRA_PKGS_PLACEHOLDER"
    pacman -S --noconfirm --needed KERNEL_EXTRA_PKGS_PLACEHOLDER
fi

# ------------------------------------------------------------------
# C.2c: Plymouth-сплэш CachyOS. Без темы plymouth показывает стандартный логотип Arch.
#       Тема cachyos-bootanimation поставляется пакетом cachyos-plymouth-bootanimation.
#       WHY без -R в plymouth-set-default-theme: initramfs всё равно пересобирается
#       в C.3, отдельная пересборка здесь лишняя.
#       WHY хук сразу после udev: plymouth выбирает DRM-устройство через udev;
#       хук стоит раньше mdadm_udev/mdrun, чтобы сплэш появился до ожидания массивов.
#       Параметр quiet splash в refind.conf уже задан — здесь его не трогаем.
# ------------------------------------------------------------------
echo "==> C.2c: Plymouth-сплэш CachyOS"
pacman -S --noconfirm --needed plymouth cachyos-plymouth-bootanimation
plymouth-set-default-theme cachyos-bootanimation
if ! grep -q '^Theme=cachyos-bootanimation' /etc/plymouth/plymouthd.conf; then
    echo "    ОШИБКА: тема cachyos-bootanimation не выставлена в /etc/plymouth/plymouthd.conf" >&2
    exit 1
fi
# \budev\b: без границ слова заденет mdadm_udev (\b не срабатывает на '_' внутри слова)
if ! grep '^HOOKS=' /etc/mkinitcpio.conf | grep -qw plymouth; then
    sed -i '/^HOOKS=/ s/\budev\b/udev plymouth/' /etc/mkinitcpio.conf
    echo "    plymouth добавлен в HOOKS"
else
    echo "    plymouth уже есть в HOOKS — OK"
fi

# ------------------------------------------------------------------
# C.2d: NVIDIA в initramfs — блэклист nouveau и ранний KMS. Только если поставлен драйвер NVIDIA.
#       Блэклист: два драйвера на одну карту конфликтуют за устройство.
#       WHY свой файл, хотя nvidia-utils уже ставит такой блэклист: правило из пакета не наше,
#       его могут убрать/переименовать, а скрипт не должен от него зависеть.
#       WHY «install … /bin/false» кроме blacklist: blacklist не мешает загрузке по зависимости
#       или явному modprobe, install-строка блокирует загрузку полностью.
#       Ранний KMS: без модулей nvidia в initramfs plymouth рисует на EFI-framebuffer (simpledrm),
#       а udev settle перед plasmalogin ждёт позднюю загрузку nvidia ~4 с — всё это время экран
#       пуст, потом модесет. Те же два drop-in'а штатно кладёт chwd (профиль nvidia-open-dkms,
#       pre_install), поэтому имена и содержимое совпадают: chwd потом корректно их уберёт.
#       Хук kms убираем: он тянет в initramfs nouveau и его прошивки (образ меньше на ~20 МБ).
#       WHY до C.3: хук modconf копирует /etc/modprobe.d в initramfs, правила должны попасть туда.
# ------------------------------------------------------------------
if pacman -Q nvidia-utils >/dev/null 2>&1; then
    echo "==> C.2d: NVIDIA — блэклист nouveau и ранний KMS"
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'NOUVEAU_BLACKLIST_EOF'
blacklist nouveau
install nouveau /bin/false
NOUVEAU_BLACKLIST_EOF
    install -d /etc/mkinitcpio.conf.d
    cat > /etc/mkinitcpio.conf.d/10-chwd.conf << 'NVIDIA_MODULES_EOF'
# Ранний KMS NVIDIA — как кладёт chwd (профиль nvidia-open-dkms, pre_install).
MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
NVIDIA_MODULES_EOF
    cat > /etc/mkinitcpio.conf.d/10-chwd-kms.conf << 'NVIDIA_KMS_EOF'
# kms не нужен: он тянет nouveau и его прошивки в initramfs, а nvidia идёт через MODULES.
HOOKS=(${HOOKS[@]/kms/})
NVIDIA_KMS_EOF
else
    echo "==> C.2d: драйвер NVIDIA не установлен — пропуск"
fi

# ------------------------------------------------------------------
# C.3: Пересборка initramfs
# ------------------------------------------------------------------
echo "==> C.3: mkinitcpio -P"
mkinitcpio -P

# ------------------------------------------------------------------
# C.4: Убедиться что rEFInd установлен на primary ESP
#       Если инсталлятор поставил "Refind" — просто дополняем.
#       Если "No Bootloader" — устанавливаем через refind-install.
# ------------------------------------------------------------------
echo "==> C.4: Проверка/установка rEFInd"
REFIND_USEDEFAULT=0
if [[ ! -d /boot/efi/EFI/refind ]]; then
    echo "    rEFInd не найден — устанавливаем через refind-install --usedefault"
    refind-install --usedefault "ESP_DEVICE_PLACEHOLDER"
    REFIND_USEDEFAULT=1
else
    echo "    rEFInd уже установлен — дополняем конфиг"
fi

# Каталог, откуда rEFInd читает refind.conf и грузит drivers_x64, зависит от режима
# установки. --usedefault кладёт бинарь в EFI/BOOT/bootx64.efi (fallback-путь прошивки)
# и не трогает NVRAM, поэтому конфиг и драйверы должны лежать рядом с ним. Если rEFInd
# уже стоит от инсталлятора (EFI/refind есть), он работает из EFI/refind с NVRAM-записью.
if (( REFIND_USEDEFAULT )); then
    REFIND_DIR=/boot/efi/EFI/BOOT
else
    REFIND_DIR=/boot/efi/EFI/refind
fi

# ------------------------------------------------------------------
# C.5: Установка ext4-драйвера для rEFInd
#       rEFInd должен читать ext4 /boot через EFI-драйвер,
#       т.к. /boot на mdraid RAID1, не на ESP
# ------------------------------------------------------------------
echo "==> C.5: Установка ext4-драйвера"
mkdir -p "$REFIND_DIR/drivers_x64"
EXT4_DRIVER=$(pacman -Ql refind | grep ext4_x64.efi | awk '{print $2}')
if [[ -n "$EXT4_DRIVER" ]]; then
    cp "$EXT4_DRIVER" "$REFIND_DIR/drivers_x64/"
    echo "    ext4_x64.efi скопирован"
else
    echo "    ОШИБКА: ext4_x64.efi не найден в пакете refind!"
    echo "    Проверьте: pacman -Ql refind | grep drivers_x64"
    exit 1
fi

# ------------------------------------------------------------------
# C.6: Установка memtest86+ (EFI) и размещение на ESP
#       rEFInd не грузит .iso-файлы напрямую (нет loopback-драйвера),
#       поэтому вместо ISO используем .efi-бинарь memtest86+ —
#       стандартный, поддерживаемый rEFInd сценарий:
#       путь EFI/tools/ обнаруживается автоматически (≥0.7.3.6),
#       стансь в refind.conf не нужна.
# ------------------------------------------------------------------
echo "==> C.6: Установка memtest86+ (EFI)"
if pacman -S --noconfirm memtest86+-efi; then
    # Определяем фактический путь .efi-бинаря (структура каталогов меняется между версиями)
    # Пакет кладёт ДВА бинаря: memtest86ia32.efi и memtest86x64.efi. Нужен x64: rEFInd
    # проверяет в PE-заголовке тип машины и 32-битный отвергает ("invalid loader file"),
    # а прежний `head -n1` по алфавиту брал именно ia32 — плитки memtest в меню не было.
    MEMTEST_EFI=$(pacman -Ql memtest86+-efi | awk '{print $2}' | grep -E '/memtest86x64\.efi$' | head -n1)
    if [[ -n "$MEMTEST_EFI" ]]; then
        mkdir -p /boot/efi/EFI/tools
        cp "$MEMTEST_EFI" /boot/efi/EFI/tools/memtest86.efi
        echo "    memtest86+ скопирован в /boot/efi/EFI/tools/memtest86.efi"
    else
        echo "    ОШИБКА: .efi-бинарь не найден в пакете memtest86+-efi"
        echo "    Проверьте: pacman -Ql memtest86+-efi | grep .efi"
    fi
else
    echo "    ОШИБКА: не удалось установить memtest86+-efi"
    echo "    Проверьте подключение к интернету и репозитории"
fi

# ------------------------------------------------------------------
# C.7: Генерация refind.conf со стансой CachyOS
#       volume — метка /boot (BOOT_LABEL), rEFInd видит её как UEFI-том
#       благодаря ext4-драйверу, независимо от того, что это mdraid
# ------------------------------------------------------------------
echo "==> C.7: Генерация $REFIND_DIR/refind.conf"
ROOT_UUID=$(blkid -s UUID -o value /dev/md1)
# Образ ядра — не хардкод: silent с откатом ставит linux, интерактив — что
# выбрал пользователь в TUI. Приоритет запрошенному пакету, иначе первый образ.
KIMG=""
if [[ -f /boot/vmlinuz-KERNEL_PKG_PLACEHOLDER ]]; then
    KIMG="vmlinuz-KERNEL_PKG_PLACEHOLDER"
else
    KIMG=$(basename "$(ls /boot/vmlinuz-* 2>/dev/null | head -n1)" 2>/dev/null || true)
fi
if [[ -z "$KIMG" ]]; then
    echo "    ОШИБКА: в /boot нет ни одного vmlinuz-*" >&2
    exit 1
fi
KVER=${KIMG#vmlinuz-}
INITRD="initramfs-$KVER.img"
if [[ ! -f "/boot/$INITRD" ]]; then
    echo "    ОШИБКА: в /boot нет $INITRD" >&2
    exit 1
fi
echo "    Ядро для стансы: /$KIMG + /$INITRD"
# Stock refind.conf от refind-install затирается нашим — сохраняем оригинал один раз,
# чтобы при сравнении или откате было с чем сверяться. Не перезаписываем старый .orig,
# иначе повторный запуск подменил бы настоящий оригинал нашим конфигом.
if [[ -f "$REFIND_DIR/refind.conf" && ! -f "$REFIND_DIR/refind.conf.orig" ]]; then
    cp "$REFIND_DIR/refind.conf" "$REFIND_DIR/refind.conf.orig"
fi
# Путь иконки — относительно ESP, поэтому берём его от реального каталога rEFInd.
REFIND_ICON_PREFIX=${REFIND_DIR#/boot/efi}
# default_selection по названию записи: без него rEFInd берёт первым самый свежий
# файл ядра и грузит LTS вместо основного. Название намеренно уникальное: rEFInd
# ищет подстроку без учёта регистра, а у автозаписей в названии есть «cachyos»
# (vmlinuz-linux-cachyos-lts) — короткое «CachyOS» выбрало бы LTS снова.
# scanfor manual: автоскан находит ядра в /boot, но без refind_linux.conf у них нет
# root= — такие записи уходят в emergency shell. Оставляем только ручные записи;
# ряд инструментов (memtest86 и т.д.) от scanfor не зависит.
# use_graphics_for linux: без него rEFInd при запуске ядра печатает «Starting vmlinuz… / Using load
# options…» в текстовом режиме; с ним — очищает экран цветом фона и ничего не выводит.
# Баннер: цвет этой заливки rEFInd берёт из левого верхнего пикселя баннера (исходник refind/screen.c,
# BltClearScreen), а без своего баннера это светлый встроенный. Поэтому баннер — чёрный, 480x140, с
# логотипом: чёрный экран между выбором записи и plymouth вместо белого. Путь — относительно каталога
# с rEFInd ($REFIND_DIR), поэтому файл кладём рядом с refind.conf. Картинку на время загрузки ядра
# rEFInd показать не умеет: при запуске ОС он только заливает экран цветом, баннер рисует лишь меню.
REFIND_BANNER_FILE=refind-banner.png
REFIND_BANNER_LINE=""
if [[ -f /root/refind-banner.png ]]; then
    install -m 644 /root/refind-banner.png "$REFIND_DIR/$REFIND_BANNER_FILE"
    REFIND_BANNER_LINE="banner $REFIND_BANNER_FILE"
fi
cat > "$REFIND_DIR/refind.conf" << REFIND_CONF_EOF
timeout 5
default_selection "CachyOS RAID1 main"
scanfor manual
use_graphics_for linux
${REFIND_BANNER_LINE}
menuentry "CachyOS RAID1 main" {
    icon     ${REFIND_ICON_PREFIX}/icons/os_arch.png
    volume   "BOOT_LABEL_PLACEHOLDER"
    loader   /$KIMG
    initrd   /$INITRD
    options  "root=UUID=${ROOT_UUID} rw quiet splash"
}
REFIND_CONF_EOF

# ------------------------------------------------------------------
# C.8: Проверка + автофикс /etc/fstab
#       archinstall честно предупреждает: RAID "too complicated to detect",
#       поэтому для pre-mounted md-массивов записей может не быть вообще.
#       Правило: mountpoint отсутствует → дописать по UUID (бэкап .bak);
#       mountpoint есть, но через /dev-путь → оставить, только предупредить
#       (грузится и так, UUID стабильнее, но молча переписывать чужое не будем).
# ------------------------------------------------------------------
echo "==> C.8: Проверка /etc/fstab"
cp -a /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"

ensure_fstab_entry() {
    local dev="$1" mountpoint="$2" fstype="$3" opts="$4" dump_pass="$5"
    local uuid
    uuid=$(blkid -s UUID -o value "$dev")
    if [[ -z "$uuid" ]]; then
        echo "    ОШИБКА: не могу прочитать UUID $dev"
        return 1
    fi
    if grep -Eq "[[:space:]]${mountpoint}[[:space:]]" /etc/fstab; then
        if grep -E "[[:space:]]${mountpoint}[[:space:]]" /etc/fstab | grep -q "UUID=$uuid"; then
            echo "    $mountpoint (UUID=$uuid) — OK"
        else
            echo "    ВНИМАНИЕ: $mountpoint есть в fstab, но не по UUID=$uuid — оставляю как есть:"
            grep -E "[[:space:]]${mountpoint}[[:space:]]" /etc/fstab | sed 's/^/      /'
        fi
    else
        echo "UUID=$uuid  $mountpoint  $fstype  $opts  $dump_pass" >> /etc/fstab
        echo "    $mountpoint отсутствовал — дописан по UUID=$uuid"
    fi
}

ensure_fstab_entry /dev/md1 / ext4 "rw,relatime" "0 1"
ensure_fstab_entry /dev/md0 /boot ext4 "rw,relatime" "0 2"
ensure_fstab_entry ESP_DEVICE_PLACEHOLDER /boot/efi vfat "rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro,nofail,x-systemd.device-timeout=5s" "0 2"

# Нормализация записи /boot/efi. archinstall/genfstab пишет её без nofail, а
# ensure_fstab_entry существующие строки не меняет. Без nofail отказ диска с этим ESP
# валит local-fs.target и загрузка уходит в emergency mode, несмотря на RAID1 для ESP.
# device-timeout ограничивает ожидание устройства, иначе systemd ждёт стандартные 90 с.
# Идемпотентно: строки, где nofail уже есть, не трогаем. Бэкап fstab сделан выше.
read -r efi_fstab_ok efi_fstab_bad <<< "$(awk '$2=="/boot/efi" { if ($4 ~ /(^|,)nofail(,|$)/) ok++; else bad++ } END { print ok+0, bad+0 }' /etc/fstab)"
if [[ "$efi_fstab_bad" -gt 0 ]]; then
    awk 'BEGIN { OFS="\t" } $2=="/boot/efi" && $4 !~ /(^|,)nofail(,|$)/ { $4=$4",nofail,x-systemd.device-timeout=5s" } { print }' /etc/fstab > /etc/fstab.normalized
    cat /etc/fstab.normalized > /etc/fstab && rm -f /etc/fstab.normalized
    echo "    /boot/efi нормализована: добавлены nofail,x-systemd.device-timeout=5s"
elif [[ "$efi_fstab_ok" -gt 0 ]]; then
    echo "    /boot/efi уже с nofail — OK"
else
    echo "    ВНИМАНИЕ: в fstab нет записи /boot/efi — нормализация пропущена"
fi

echo "    Итоговый fstab:"
cat /etc/fstab | sed 's/^/      /'

# ------------------------------------------------------------------
# C.9: Локаль/пользователи — только если Фаза B была silent.
#       Признак: сценарный файл, подложенный внешним скриптом в /tmp.
#       TUI-режим уже всё настроил сам — блок пропускается.
#       Пароли живут только в этом файле (600) и затираются shred в конце.
# ------------------------------------------------------------------
if [[ -f /root/p510-scenario.env ]]; then
    echo "==> C.9: Локаль и пользователи из сценария"
    chmod 600 /root/p510-scenario.env
    set -a
    # shellcheck disable=SC1090
    source /root/p510-scenario.env
    set +a

    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    hwclock --systohc || true
    sed -i "s/^#\(${LOCALE%%.*}.*UTF-8\)/\1/" /etc/locale.gen
    # Системные локали: en_US, ru_RU, uk_UA (все UTF-8); LANG по умолчанию — $LOCALE (en_US.UTF-8).
    # WHY: ru/uk нужны для русскоязычных/украинских приложений и данных, а системный язык
    # оставляем английским, чтобы логи и сообщения утилит были единообразными.
    LOCALES=${LOCALES:-en_US.UTF-8 ru_RU.UTF-8 uk_UA.UTF-8}
    for loc in $LOCALES; do
        sed -i -E "s/^#\s*(${loc//./\\.} UTF-8)/\1/" /etc/locale.gen
    done
    locale-gen || echo "    ВНИМАНИЕ: locale-gen с ошибками — проверьте /etc/locale.gen"
    echo "LANG=$LOCALE" > /etc/locale.conf
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
    # Раскладки: us, ru, ua; переключение Ctrl+Shift по кругу (XKB-опция grp:ctrl_shift_toggle).
    # WHY до useradd: kxkbrc кладём в /etc/skel, а useradd -m копирует skel только при создании
    # пользователя; X11-конфиг — системные раскладки для сеанса/экрана входа.
    # Консоль (vconsole) остаётся на KEYMAP=$KEYMAP: переключение по кругу есть только в графике.
    KB_LAYOUTS=${KB_LAYOUTS:-us,ru,ua}
    KB_OPTIONS=${KB_OPTIONS:-grp:ctrl_shift_toggle}
    install -d /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/00-keyboard.conf << KB_X11_EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KB_LAYOUTS"
    Option "XkbModel" "pc105"
    Option "XkbOptions" "$KB_OPTIONS"
EndSection
KB_X11_EOF
    install -d /etc/skel/.config
    cat > /etc/skel/.config/kxkbrc << KB_KDE_EOF
[Layout]
LayoutList=$KB_LAYOUTS
LayoutLoopCount=-1
Model=pc105
Options=$KB_OPTIONS
ResetOldOptions=true
SwitchMode=Global
Use=true
KB_KDE_EOF

    # Энергопитание: экран блокируется через 15 мин, монитор гаснет через 30 мин, сон отключён.
    # WHY: хост держит LXC-контейнеры с AI и доступен по SSH — уснувшая машина обрывает и то и другое.
    # Затемнение выключено, чтобы оно не срабатывало раньше блокировки. TurnOffDisplayIdleTimeoutWhenLockedSec
    # задан явно: по умолчанию заблокированный экран гаснет через 60 с, а не через заданные 30 мин.
    # Ключи сверены со схемой powerdevil 6.7.5; Timeout в kscreenlockerrc — в минутах, в powerdevilrc — в секундах.
    cat > /etc/skel/.config/kscreenlockerrc << 'SKEL_LOCK_EOF'
[Daemon]
Autolock=true
Timeout=15
SKEL_LOCK_EOF
    : > /etc/skel/.config/powerdevilrc
    for power_profile in AC Battery LowBattery; do
        cat >> /etc/skel/.config/powerdevilrc << SKEL_POWER_EOF
[$power_profile][Display]
DimDisplayWhenIdle=false
TurnOffDisplayIdleTimeoutSec=1800
TurnOffDisplayIdleTimeoutWhenLockedSec=1800
TurnOffDisplayWhenIdle=true

[$power_profile][SuspendAndShutdown]
AutoSuspendAction=0

SKEL_POWER_EOF
    done
    # Страховка на уровне системы: маскировка гасит сон и из меню, и для других пользователей/greeter.
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

    # Первый вход в KDE: панель Plasma вверху экрана; часы в панели — 24 ч, секунды, дата «Oct 09 2026».
    # WHY одноразовый автозапуск, а не копия plasma-org.kde.plasma.desktop-appletsrc: готовый файл
    # привязан к машине (UUID активности, номера экранов, ScreenMapping) и ломает рабочий стол нового
    # пользователя, а при первом запуске Plasma сама создаёт раскладку по умолчанию (панель внизу).
    # Скрипт ждёт появления панели, меняет настройки через скриптовый интерфейс plasmashell и убирает
    # себя из автозапуска. Ключи часов: use24hFormat 0/1/2 = 12 ч/по региону/24 ч, showSeconds 0/1/2 =
    # никогда/в подсказке/всегда (схема applets/digital-clock/main.xml в plasma-workspace).
    install -d /etc/skel/.config/autostart
    cat > /usr/local/bin/p510-plasma-first-login << 'PLASMA_FIRST_LOGIN_EOF'
#!/bin/bash
# Первый вход в KDE: панель Plasma наверх, часы в панели — 24 ч с секундами и датой «Oct 09 2026»;
# затем убирает себя из автозапуска.
set -u
qdbus_bin=$(command -v qdbus6 || command -v qdbus-qt6 || true)
[[ -n "$qdbus_bin" ]] || exit 0
plasma_script='
var ps = panels();
for (var i = 0; i < ps.length; i++) {
    var p = ps[i];
    p.location = "top";
    var ids = p.widgetIds;
    for (var j = 0; j < ids.length; j++) {
        var w = p.widgetById(ids[j]);
        if (w.type == "org.kde.plasma.digitalclock") {
            w.currentConfigGroup = ["Appearance"];
            w.writeConfig("use24hFormat", 2);
            w.writeConfig("showSeconds", 2);
            w.writeConfig("showDate", true);
            w.writeConfig("dateFormat", "custom");
            w.writeConfig("customDateFormat", "MMM dd yyyy");
            w.reloadConfig();
        }
    }
}'
for _ in $(seq 1 60); do
    panel_count=$("$qdbus_bin" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript 'print(panels().length)' 2>/dev/null || true)
    if [[ "$panel_count" =~ ^[1-9][0-9]*$ ]]; then
        "$qdbus_bin" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$plasma_script" >/dev/null 2>&1
        rm -f "$HOME/.config/autostart/p510-plasma-first-login.desktop"
        exit 0
    fi
    sleep 1
done
PLASMA_FIRST_LOGIN_EOF
    chmod 755 /usr/local/bin/p510-plasma-first-login
    cat > /etc/skel/.config/autostart/p510-plasma-first-login.desktop << 'PLASMA_FIRST_LOGIN_DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Plasma first-login tweaks (panel on top, 24h clock)
Exec=/usr/local/bin/p510-plasma-first-login
OnlyShowIn=KDE;
PLASMA_FIRST_LOGIN_DESKTOP_EOF

    if [[ ! -x "USER_SHELL_PLACEHOLDER" ]]; then
        echo "    ОШИБКА: shell USER_SHELL_PLACEHOLDER отсутствует в таргете (нет пакета?)" >&2
        exit 1
    fi
    useradd -m -G wheel -s "USER_SHELL_PLACEHOLDER" "$USERNAME"
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    echo "root:$ROOT_PASSWORD" | chpasswd

    # Без ~/.p10k.zsh первый запуск терминала открывает мастер Powerlevel10k.
    # Только zsh: штатный установщик CachyOS по умолчанию ставит fish, там p10k не нужен.
    if [[ "USER_SHELL_PLACEHOLDER" == */zsh ]]; then
        if [[ -f /root/p10k.zsh ]]; then
            SRC=/root/p10k.zsh
        elif [[ -f /usr/share/zsh-theme-powerlevel10k/config/p10k-rainbow.zsh ]]; then
            SRC=/usr/share/zsh-theme-powerlevel10k/config/p10k-rainbow.zsh
        else
            SRC=""
            echo "    ВНИМАНИЕ: нет ни /root/p10k.zsh, ни штатного пресета p10k — мастер откроется при первом запуске"
        fi
        if [[ -n "$SRC" ]]; then
            install -o "$USERNAME" -g "$USERNAME" -m 644 "$SRC" "/home/$USERNAME/.p10k.zsh"
            echo "    p10k: конфиг из $SRC → /home/$USERNAME/.p10k.zsh"
        fi
    fi
    rm -f /root/p10k.zsh

    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    systemctl enable NetworkManager
    # sshd нужен, чтобы стенд был доступен удалённо: без него после установки
    # проверить его можно только с консоли. Пакет openssh входит в набор сценария.
    if [[ -f /usr/lib/systemd/system/sshd.service ]]; then
        systemctl enable sshd
        echo "    sshd включён"
    else
        echo "    sshd.service нет (openssh не ставился?) — пропускаю"
    fi
    # Дисплей-менеджер CachyOS — plasmalogin (пакет plasma-login-manager).
    # Не sddm: оба сервиса конфликтуют, включаем только при наличии.
    if [[ -f /usr/lib/systemd/system/plasmalogin.service ]]; then
        systemctl enable plasmalogin
        echo "    plasmalogin (KDE) включён"
    else
        echo "    ВНИМАНИЕ: plasmalogin.service нет (KDE-набор не ставился?) — DM не включён"
    fi

    shred -u /root/p510-scenario.env
    echo "    Пользователь $USERNAME создан, сценарный файл затёрт"
else
    echo "==> C.9: сценарного файла нет (TUI-режим) — пропускаю"
fi

# ------------------------------------------------------------------
# C.10: Утилиты + LXC с пробросом NVIDIA GPU (контейнеры для AI)
#       Выполняется в обоих режимах (не зависит от сценария).
#       WHY непривилегированные контейнеры по умолчанию: официальный хук LXC для NVIDIA
#       (/usr/share/lxc/hooks/nvidia, через libnvidia-container) работает ТОЛЬКО в userns;
#       он же пробрасывает /dev/nvidia*, libcuda и nvidia-smi ровно хостовой версии,
#       так что в контейнере драйвер ставить не нужно.
# ------------------------------------------------------------------
echo "==> C.10: Утилиты и LXC"
pacman -S --noconfirm --needed mc htop btop duf gdu lxc lxcfs libnvidia-container dnsmasq rsync wget gnupg xz squashfs-tools

# Игровой набор — ровно то, что ставит кнопка «Install gaming» в CachyOS Hello (Welcome):
# cachyos-gaming-meta (proton-cachyos, wine-cachyos, umu, lib32-библиотеки) и
# cachyos-gaming-applications (steam, lutris, heroic, gamescope, mangohud...).
# WHY после драйвера NVIDIA (C.2b-extra): lib32-nvidia-utils уже стоит и закрывает
# зависимость lib32-vulkan-driver — иначе pacman --noconfirm выберет первый попавшийся
# провайдер (например, radeon/intel). Около 2 ГиБ загрузки; отключается INSTALL_GAMING=no.
if [[ "${INSTALL_GAMING:-yes}" == "yes" ]]; then
    pacman -S --noconfirm --needed cachyos-gaming-meta cachyos-gaming-applications
else
    echo "    INSTALL_GAMING=no — игровой набор пропущен"
fi

# subuid/subgid для root: диапазон 1000000-1065535 (у обычного пользователя useradd даёт 100000+)
for idmap_file in /etc/subuid /etc/subgid; do
    grep -q '^root:' "$idmap_file" 2>/dev/null || echo "root:1000000:65536" >> "$idmap_file"
done

install -d /etc/lxc /etc/lxc/profiles
cat > /etc/lxc/default.conf << 'LXC_DEFAULT_EOF'
# Сеть: veth в мост lxcbr0 (его поднимает lxc-net.service, DHCP/DNS через dnsmasq)
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 10:66:6a:xx:xx:xx
# Все новые контейнеры непривилегированные: uid/gid 0 внутри = 1000000 на хосте.
# Обязательное условие для NVIDIA-хука LXC (он работает только в userns).
lxc.idmap = u 0 1000000 65536
lxc.idmap = g 0 1000000 65536
LXC_DEFAULT_EOF

# Штатный /etc/default/lxc ставит USE_LXC_BRIDGE=false и перебивает дефолт скрипта lxc-net,
# поэтому мост включаем явно отдельным файлом (без него lxcbr0 не создаётся, сервис «active»).
cat > /etc/default/lxc-net << 'LXC_NET_EOF'
USE_LXC_BRIDGE="true"
LXC_BRIDGE="lxcbr0"
LXC_ADDR="10.0.3.1"
LXC_NETMASK="255.255.255.0"
LXC_NETWORK="10.0.3.0/24"
LXC_DHCP_RANGE="10.0.3.2,10.0.3.254"
LXC_DHCP_MAX="253"
LXC_NET_EOF

cat > /etc/lxc/profiles/gpu-nvidia.conf << 'LXC_GPU_EOF'
# NVIDIA GPU для контейнера: подключение — строка в конфиге контейнера
#   lxc.include = /etc/lxc/profiles/gpu-nvidia.conf
# (sudo lxc-ai-create ИМЯ делает это сам). Хук пробрасывает /dev/nvidia*, libcuda, NVML и
# nvidia-smi хостовой версии; только непривилегированные контейнеры (idmap — в default.conf).
lxc.environment = NVIDIA_VISIBLE_DEVICES=all
lxc.environment = NVIDIA_DRIVER_CAPABILITIES=compute,utility,video,graphics
lxc.hook.mount = /usr/share/lxc/hooks/nvidia
LXC_GPU_EOF

# NetworkManager не должен управлять мостом и veth контейнеров
install -d /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-lxc-unmanaged.conf << 'LXC_NM_EOF'
[keyfile]
unmanaged-devices=interface-name:lxcbr0;interface-name:veth*
LXC_NM_EOF

# Обычный пользователь тоже может запускать контейнеры: до 10 veth на lxcbr0
if [[ -n "${USERNAME:-}" ]]; then
    grep -q "^$USERNAME veth lxcbr0" /etc/lxc/lxc-usernet 2>/dev/null || echo "$USERNAME veth lxcbr0 10" >> /etc/lxc/lxc-usernet
fi

cat > /usr/local/bin/lxc-ai-create << 'LXC_AI_EOF'
#!/bin/bash
# lxc-ai-create — контейнер для AI/ML с пробросом NVIDIA GPU (непривилегированный)
# Использование: sudo lxc-ai-create ИМЯ [дистрибутив [релиз]]   (по умолчанию ubuntu noble)
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
    echo "Запускать от root: sudo lxc-ai-create ИМЯ [дистрибутив [релиз]]" >&2
    exit 1
fi
NAME=${1:-}
DISTRO=${2:-ubuntu}
RELEASE=${3:-noble}
if [[ -z "$NAME" ]]; then
    echo "Использование: sudo lxc-ai-create ИМЯ [дистрибутив [релиз]]" >&2
    exit 1
fi
if [[ ! -e /usr/share/lxc/hooks/nvidia || ! -x /usr/bin/nvidia-container-cli ]]; then
    echo "Нет NVIDIA-хука LXC или libnvidia-container — GPU пробросить нельзя" >&2
    exit 1
fi
lxc-create -n "$NAME" -t download -- -d "$DISTRO" -r "$RELEASE" -a amd64
echo "lxc.include = /etc/lxc/profiles/gpu-nvidia.conf" >> "/var/lib/lxc/$NAME/config"
lxc-start -n "$NAME" -d
ip_addr=""
for _ in $(seq 1 30); do
    ip_addr=$(lxc-info -n "$NAME" -iH 2>/dev/null | head -n 1 || true)
    [[ -n "$ip_addr" ]] && break
    sleep 1
done
echo "Контейнер $NAME запущен (${ip_addr:-IP ещё не получен}). Проверка GPU:"
echo "  sudo lxc-attach -n $NAME -- nvidia-smi"
LXC_AI_EOF
chmod 755 /usr/local/bin/lxc-ai-create

systemctl enable lxc-net lxcfs

echo "==> [Фаза C] Донастройка завершена"
CHROOT_EOF

chmod +x /mnt/root/chroot-setup.sh

# Подстановка переменных в chroot-скрипт
sed -i "s|ESP_DEVICE_PLACEHOLDER|/dev/$PART1_1|g" /mnt/root/chroot-setup.sh
sed -i "s|BOOT_LABEL_PLACEHOLDER|$BOOT_LABEL|g" /mnt/root/chroot-setup.sh
sed -i "s|KERNEL_PKG_PLACEHOLDER|$KERNEL_PKG|g; s|SWAP_KERNEL_PLACEHOLDER|$SWAP_KERNEL|g; s|USER_SHELL_PLACEHOLDER|$USER_SHELL|g; s|KERNEL_EXTRA_PKGS_PLACEHOLDER|$KERNEL_EXTRA_PKGS|g" /mnt/root/chroot-setup.sh

# Сценарный файл — в таргет для блока C.9 (только unattended; в интерактиве
# SCENARIO_FILE пуст и копировать нечего). Права 600 — там пароли.
if [[ "$MODE" == "unattended" ]]; then
    cp "$SCENARIO_FILE" /mnt/root/p510-scenario.env
    chmod 600 /mnt/root/p510-scenario.env

    # Путь к ассету берём от расположения скрипта, а не от CWD: запуск возможен из любого каталога.
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    P10K_ASSET="$SCRIPT_DIR/assets/p10k-extravagant.zsh"
    if [[ -f "$P10K_ASSET" ]]; then
        cp "$P10K_ASSET" /mnt/root/p10k.zsh
        chmod 644 /mnt/root/p10k.zsh
    else
        # Отсутствие ассета не ошибка: C.9 откатится на штатный пресет rainbow из пакета zsh-theme-powerlevel10k.
        echo "    p10k: $P10K_ASSET не найден — будет использован штатный пресет rainbow"
    fi
fi

# Баннер rEFInd нужен в обоих режимах (меню есть всегда), поэтому вне блока unattended.
# Путь считаем заново: в интерактиве SCRIPT_DIR из блока выше не задан.
BANNER_ASSET="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assets/refind-banner.png"
if [[ -f "$BANNER_ASSET" ]]; then
    cp "$BANNER_ASSET" /mnt/root/refind-banner.png
    chmod 644 /mnt/root/refind-banner.png
else
    # Не ошибка: C.7 тогда не пишет banner, rEFInd использует встроенный (светлый фон при запуске ОС).
    echo "    banner: $BANNER_ASSET не найден — будет встроенный баннер rEFInd"
fi

# Выполнение chroot-скрипта
echo "==> Запуск настройки в chroot"
if [[ ! -x /mnt/root/chroot-setup.sh ]]; then
    log_error "/mnt/root/chroot-setup.sh отсутствует — heredoc не записался?"
    ls -la /mnt/root/ || true
    exit 1
fi
arch-chroot /mnt /bin/bash /root/chroot-setup.sh

# Блок C.9 затирает сценарный файл изнутри; это — страховка на случай обрыва.
rm -f /mnt/root/p510-scenario.env /mnt/root/refind-banner.png

# ==============================================================================
# ФАЗА D — Зеркалирование ESP + автохук
# ==============================================================================

# ==============================================================================
# Шаг 14: Второй ESP — начальная копия + вторая NVRAM-запись
# ==============================================================================
log_step "Шаг 14: Фаза D — настройка второго ESP"

echo "==> Монтирование второго ESP"
mkdir -p /mnt/efi_b
mount "/dev/$PART2_1" /mnt/efi_b

echo "==> Синхронизация ESP (primary → backup)"
rsync -a --delete /mnt/boot/efi/ /mnt/efi_b/

echo "==> Размонтирование второго ESP"
umount /mnt/efi_b
rmdir /mnt/efi_b

echo "==> Создание NVRAM-записей для обоих ESP"
# efibootmgr работает на хосте, а не в chroot: NVRAM доступна только из запущенного ядра.
# Записи ищем по точной метке: поиск по подстроке "rEFInd" задел бы чужие записи,
# например стоковую "rEFInd Boot Manager" от инсталлятора.
boot_ids_by_label() {
    efibootmgr | awk -v want="$1" '
        /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {
            id = substr($0, 5, 4)
            rest = substr($0, 9)
            sub(/^[* ]+/, "", rest)
            split(rest, parts, "\t")
            sub(/ +$/, "", parts[1])
            if (parts[1] == want) print id
        }'
}

# Повторный прогон без удаления старых записей плодит дубли в NVRAM.
for staleLabel in "rEFInd (primary)" "rEFInd (backup)"; do
    while read -r staleId; do
        echo "    удаляю старую запись Boot$staleId ($staleLabel)"
        efibootmgr -b "$staleId" -B >/dev/null
    done < <(boot_ids_by_label "$staleLabel")
done

# Путь к загрузчику зависит от того, как rEFInd попал на ESP: refind-install кладёт
# fallback-загрузчик в EFI/BOOT, а если его нет — грузим из собственного каталога.
LOADER='\EFI\BOOT\BOOTX64.EFI'
if [[ ! -f /mnt/boot/efi/EFI/BOOT/bootx64.efi && -f /mnt/boot/efi/EFI/refind/refind_x64.efi ]]; then
    LOADER='\EFI\refind\refind_x64.efi'
fi
echo "    loader: $LOADER"

# ESP всегда на разделе 1 каждого диска (см. PART1_1/PART2_1 выше).
efibootmgr --create --disk "/dev/$DISK1" --part 1 \
    --label "rEFInd (primary)" --loader "$LOADER" >/dev/null
echo "    создана запись rEFInd (primary) на /dev/$DISK1"
efibootmgr --create --disk "/dev/$DISK2" --part 1 \
    --label "rEFInd (backup)" --loader "$LOADER" >/dev/null
echo "    создана запись rEFInd (backup) на /dev/$DISK2"

# Номер, который вернул create, не используем: id берём по метке из вывода efibootmgr.
PRIMARY_BOOT_ID=$(boot_ids_by_label "rEFInd (primary)" | head -n 1)
BACKUP_BOOT_ID=$(boot_ids_by_label "rEFInd (backup)" | head -n 1)
if [[ -z "$PRIMARY_BOOT_ID" || -z "$BACKUP_BOOT_ID" ]]; then
    echo "ОШИБКА: созданные NVRAM-записи не найдены в выводе efibootmgr" >&2
    exit 1
fi

# primary и backup — первыми; остальные записи (Shell, Windows и т.п.) сохраняем
# в прежнем порядке. Дубли в BootOrder отбрасываем, иначе efibootmgr -o примет
# их как есть и порядок станет непредсказуемым.
ORDER_CURRENT=$(efibootmgr | awk '/^BootOrder:/ { print $2 }')
IFS=, read -ra ORDER_ARRAY <<< "$ORDER_CURRENT"
NEW_ORDER="$PRIMARY_BOOT_ID,$BACKUP_BOOT_ID"
for orderId in "${ORDER_ARRAY[@]}"; do
    case ",$NEW_ORDER," in
        *",$orderId,"*) continue ;;
    esac
    NEW_ORDER+=",$orderId"
done
efibootmgr -o "$NEW_ORDER" >/dev/null
echo "==> Итоговый порядок загрузки:"
efibootmgr | grep BootOrder

# ==============================================================================
# Шаг 15: Установка pacman-хука синхронизации ESP
# ==============================================================================
log_step "Шаг 15: Установка pacman-хука синхронизации ESP"

# Создание каталога для хуков
mkdir -p /mnt/etc/pacman.d/hooks

# Создание хука
cat > /mnt/etc/pacman.d/hooks/95-refind-sync-efi.hook << HOOK_EOF
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = linux-cachyos
Target = refind
Target = mkinitcpio
Target = memtest86+-efi

[Action]
Description = Sync primary ESP -> backup ESP disk
When = PostTransaction
Exec = /usr/local/bin/sync-efi-mirror.sh
HOOK_EOF

# Создание скрипта синхронизации.
# Привязка по PARTUUID, а не /dev/sdX: буквы дисков плавают при перестановке
# SATA-портов и добавлении NVMe, PARTUUID записан в GPT и стабилен.
mkdir -p /mnt/usr/local/bin

BACKUP_PARTUUID=$(blkid -s PARTUUID -o value "/dev/$PART2_1")
if [[ -n "$BACKUP_PARTUUID" ]]; then
    BACKUP_SRC="/dev/disk/by-partuuid/$BACKUP_PARTUUID"
    echo "==> Backup ESP: $BACKUP_SRC (PARTUUID=$BACKUP_PARTUUID)"
else
    log_warn "PARTUUID для /dev/$PART2_1 не читается — откат на прямой путь"
    BACKUP_SRC="/dev/$PART2_1"
fi

cat > /mnt/usr/local/bin/sync-efi-mirror.sh << SYNC_SCRIPT_EOF
#!/bin/bash
set -euo pipefail

PRIMARY_ESP=/boot/efi
BACKUP_SRC=$BACKUP_SRC
MOUNT_POINT=/run/efi-backup-sync

# Робастный cleanup: umount/rmdir с || true — если mount не удался,
# trap на EXIT не должен ронять pacman-хук ложной ошибкой.
cleanup() {
    umount "\$MOUNT_POINT" 2>/dev/null || true
    rmdir "\$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -d "\$PRIMARY_ESP" ]]; then
    echo "sync-efi-mirror: \$PRIMARY_ESP отсутствует" >&2
    exit 1
fi
if [[ ! -b "\$BACKUP_SRC" ]]; then
    echo "sync-efi-mirror: источник \$BACKUP_SRC не блочное устройство" >&2
    exit 1
fi

mkdir -p "\$MOUNT_POINT"
mount "\$BACKUP_SRC" "\$MOUNT_POINT"

rsync -a --delete "\$PRIMARY_ESP"/ "\$MOUNT_POINT"/
SYNC_SCRIPT_EOF

chmod +x /mnt/usr/local/bin/sync-efi-mirror.sh

# ==============================================================================
# Финал
# ==============================================================================
log_step "Завершение установки"

# Перезагрузка во время ресинка безопасна, но отказоустойчивость появляется только
# после его окончания — до тех пор зеркало фактически не защищает.
echo "==> Ожидание окончания ресинка RAID (отказоустойчивость — только после него)"
# || true: без активного ресинка mdadm --wait завершается ненулевым кодом — это норма.
mdadm --wait /dev/md0 /dev/md1 || true

echo "==> Размонтирование всех разделов"
umount -R /mnt

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Установка завершена!                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo "Для завершения:"
echo "  1. Извлеките установочный носитель"
echo "  2. Перезагрузитесь (reboot)"
echo "  3. В UEFI Boot Menu (F12) выберите запись rEFInd"
echo
echo "Для проверки отказоустойчивости:"
echo "  - Отключите один диск, загрузитесь с другого"
echo "  - Убедитесь, что RAID-массивы поднялись в degraded-режиме"
echo "  - Подключите диск обратно и восстановите:"
echo "      mdadm --manage /dev/md0 --add /dev/${DISK1}2"
echo "      mdadm --manage /dev/md1 --add /dev/${DISK1}3"
echo
echo -e "${YELLOW}НЕ перезагружайтесь автоматически — извлеките носитель вручную!${NC}"
