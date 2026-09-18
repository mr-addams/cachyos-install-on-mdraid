#!/bin/bash
# ==============================================================================
# Bootstrap для запуска установки из CachyOS live-ISO.
#
# Запуск одной строкой (root):
#   curl -fsSL https://raw.githubusercontent.com/mr-addams/cachyos-install-on-mdraid/main/boot.sh | sudo bash
#
# Для живого железа — пин на тег, а не на плавающий main:
#   curl -fsSL https://raw.githubusercontent.com/mr-addams/cachyos-install-on-mdraid/v1.0.0/boot.sh | sudo bash
#
# Переменные окружения:
#   P510_REPO — owner/repo (дефолт: mr-addams/cachyos-install-on-mdraid)
#   P510_REF  — ветка/тег (дефолт: main)
# ==============================================================================
set -euo pipefail

P510_REPO="${P510_REPO:-mr-addams/cachyos-install-on-mdraid}"
P510_REF="${P510_REF:-main}"
WORKDIR=/tmp/p510-install
MAIN_SCRIPT="install-cachyos-refind-mdraid.sh"

if [[ $EUID -ne 0 ]]; then
    echo "Запускайте от root (в live-ISO: ... | sudo bash)" >&2
    exit 1
fi

echo "==> P510 bootstrap: ${P510_REPO} @ ${P510_REF}"

# Git в live-ISO может отсутствовать — доустановить до клонирования.
if ! command -v git &> /dev/null; then
    echo "==> git не найден, устанавливаю"
    pacman -Sy --noconfirm git
fi

if ! command -v curl &> /dev/null; then
    echo "==> curl не найден, устанавливаю"
    pacman -Sy --noconfirm curl
fi

rm -rf "$WORKDIR"
if ! git clone --depth 1 --branch "$P510_REF" "https://github.com/${P510_REPO}.git" "$WORKDIR"; then
    echo "Не удалось склонировать ${P510_REPO} @ ${P510_REF}" >&2
    echo "Проверьте имя репо и что ref (ветка/тег) существует." >&2
    exit 1
fi

if [[ ! -f "$WORKDIR/$MAIN_SCRIPT" ]]; then
    echo "В репозитории нет $MAIN_SCRIPT" >&2
    exit 1
fi

echo "==> Запускаю $MAIN_SCRIPT"
exec bash "$WORKDIR/$MAIN_SCRIPT"
