#!/bin/bash
#
# Flash a built PineVoice (BL606P / E907) firmware directly from the host,
# bypassing the dev container. The prebuilt bflb flashtool is a native x86-64
# binary and the board's ISP interface enumerates on the host, so flashing does
# not need the container (which only exists for the build toolchain).
#
# In download mode the BL606P exposes its own USB device as /dev/ttyACM*; the
# always-present /dev/ttyUSB* is the UART-bridge console, NOT the ISP port.
# We therefore target ttyACM* for flashing.
#
# Usage: ./flash-from-host.sh [--app-only] [--port /dev/ttyACMx] [--console]
#
set -euo pipefail

readonly CHIPNAME="bl606p"
readonly BAUDRATE="2000000"
readonly CONSOLE_BAUDRATE="2000000"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT
readonly E907_DIR="$REPO_ROOT/solutions/pinevoice_fw_e907"
readonly BOARD_DIR="$REPO_ROOT/boards/bl606p_pinevoice_e907"
readonly TOOL="$REPO_ROOT/tools/flashtool/bflb_iot_tool-ubuntu"

readonly FIRMWARE="$E907_DIR/yoc_rfpa.bin"
readonly MEDIA="$E907_DIR/generated/littlefs.bin"
readonly PARTITION="$BOARD_DIR/configs/partition.toml"
readonly EFLASH_CFG_SRC="$BOARD_DIR/configs/eflash_loader_cfg.ini"
readonly EFLASH_CFG_DST="$REPO_ROOT/tools/flashtool/chips/bl606p/eflash_loader/eflash_loader_cfg.ini"

APP_ONLY=0
OPEN_CONSOLE=0
PORT=""

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo ">> $*"
}

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

Flash a built PineVoice firmware from the host.

Options:
  --app-only          Flash firmware + partition table only (skip media/mfg).
                      Use for a quick reflash once a full flash has been done.
  --port /dev/ttyACMx Explicit ISP serial port. Auto-detected by default.
  --console           Open a serial console (tio) after flashing.
  -h, --help          Show this help.

The board must be in download mode BEFORE running: power off, hold the
center ring button, power on, then run this immediately (there is a timeout).
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --app-only) APP_ONLY=1; shift ;;
            --console)  OPEN_CONSOLE=1; shift ;;
            --port)
                [ $# -ge 2 ] || die "--port requires an argument (e.g. --port /dev/ttyACM0)"
                PORT="$2"; shift 2 ;;
            -h|--help)  usage; exit 0 ;;
            *) usage >&2; die "unknown argument: $1" ;;
        esac
    done
}

# The mfg image tracks the build's commit hash and both a base and an _rfpa
# variant exist; flash.sh flashes the base one, so select the single non-rfpa
# candidate rather than hardcoding a hash that changes between releases.
select_mfg() {
    shopt -s nullglob
    local candidates=( "$BOARD_DIR"/bootimgs/bl606p_mfg_gu_*.bin )
    shopt -u nullglob
    local base=()
    local f
    for f in "${candidates[@]}"; do
        case "$f" in
            *_rfpa.bin) ;;
            *) base+=( "$f" ) ;;
        esac
    done
    [ ${#base[@]} -ne 0 ] || die "no mfg image found in $BOARD_DIR/bootimgs (expected bl606p_mfg_gu_*.bin)"
    [ ${#base[@]} -eq 1 ] || die "expected exactly one base mfg image, found ${#base[@]}: ${base[*]}"
    MFG="${base[0]}"
}

check_tooling() {
    [ -x "$TOOL" ] || die "flashtool not found or not executable: $TOOL"
    [ -f "$EFLASH_CFG_SRC" ] || die "missing eflash loader config: $EFLASH_CFG_SRC"
    [ -d "$(dirname "$EFLASH_CFG_DST")" ] || die "flashtool config dir missing: $(dirname "$EFLASH_CFG_DST")"
}

# Refuse to flash unless the artifacts a build produces are present, so a stale
# or absent build is reported clearly instead of the flashtool failing cryptically.
check_build() {
    [ -f "$FIRMWARE" ] || die "no firmware to flash: $FIRMWARE not found. Build first (./package.sh)."
    [ -s "$FIRMWARE" ] || die "firmware image is empty: $FIRMWARE. Rebuild (./package.sh)."
    [ -f "$PARTITION" ] || die "missing partition table: $PARTITION"

    if [ "$APP_ONLY" -eq 0 ]; then
        [ -f "$MEDIA" ] || die "no media image: $MEDIA not found. Build first, or use --app-only."
        [ -s "$MEDIA" ] || die "media image is empty: $MEDIA. Rebuild, or use --app-only."
        [ -f "$MFG" ] || die "no mfg image: $MFG not found."
    fi
}

detect_port() {
    if [ -n "$PORT" ]; then
        info "using specified port: $PORT"
    else
        shopt -s nullglob
        local acm=( /dev/ttyACM* )
        shopt -u nullglob
        case ${#acm[@]} in
            0) die "no /dev/ttyACM* device found. Put the board in download mode (power off, hold center ring, power on) and retry, or pass --port." ;;
            1) PORT="${acm[0]}"; info "auto-detected ISP port: $PORT" ;;
            *) die "multiple ISP ports found (${acm[*]}); disambiguate with --port /dev/ttyACMx" ;;
        esac
    fi

    [ -c "$PORT" ] || die "$PORT is not a character device"
    if [ ! -w "$PORT" ] || [ ! -r "$PORT" ]; then
        die "no read/write access to $PORT. Add yourself to the owning group (e.g. 'sudo usermod -aG dialout $USER' then re-login), or run with sufficient privileges."
    fi
}

flash() {
    info "staging eflash loader config"
    cp "$EFLASH_CFG_SRC" "$EFLASH_CFG_DST"

    local args=(
        --interface=uart
        --baudrate="$BAUDRATE"
        --chipname="$CHIPNAME"
        --firmware="$FIRMWARE"
        --pt="$PARTITION"
        --port "$PORT"
    )
    if [ "$APP_ONLY" -eq 0 ]; then
        args+=( --media="$MEDIA" --mfg="$MFG" )
        info "full flash: firmware + partition + media + mfg"
    else
        info "app-only flash: firmware + partition"
    fi

    # Run from the solution dir to match the tool's proven working directory.
    cd "$E907_DIR"
    info "flashing on $PORT at $BAUDRATE baud (do not disconnect)"

    # The flashtool exits 0 even when the chip never handshakes, so its exit
    # status alone cannot be trusted; capture the output and inspect it.
    local logfile status
    logfile="$(mktemp)"
    set +e
    "$TOOL" "${args[@]}" 2>&1 | tee "$logfile"
    status=${PIPESTATUS[0]}
    set -e

    if [ "$status" -ne 0 ]; then
        rm -f "$logfile"
        die "flashtool exited with status $status"
    fi

    if grep -qiE 'shake ?hand fail|retry fail|shakehand fail|reset cpu fail|connection timed out|burn return with[[:space:]].*fail' "$logfile"; then
        rm -f "$logfile"
        die "flash FAILED: the chip did not respond (handshake/programming error).
       The board is almost certainly not in download mode. Re-enter it and retry:
         1) power off the PineVoice
         2) hold the center ring (boot) button
         3) power on while still holding the button
         4) run this script immediately (the ISP window times out quickly)"
    fi

    if ! grep -qiE 'burn return with success|all.?success|program finished|verify success' "$logfile"; then
        rm -f "$logfile"
        die "could not confirm a successful flash from the tool output.
       Not claiming success. Review the log above and retry if needed."
    fi

    rm -f "$logfile"
}

open_console() {
    command -v tio >/dev/null 2>&1 || die "--console requested but 'tio' is not installed (sudo apt install tio)"

    # The ISP ttyACM* disappears on reset; the runtime console is normally the
    # UART bridge (ttyUSB*), falling back to a re-enumerated ttyACM*.
    local console=""
    shopt -s nullglob
    local usb=( /dev/ttyUSB* ) acm=( /dev/ttyACM* )
    shopt -u nullglob
    if [ ${#usb[@]} -ge 1 ]; then
        console="${usb[0]}"
    elif [ ${#acm[@]} -ge 1 ]; then
        console="${acm[0]}"
    else
        die "no serial console device (/dev/ttyUSB* or /dev/ttyACM*) found after flashing"
    fi

    info "opening console on $console at $CONSOLE_BAUDRATE baud (Ctrl-t q to quit)"
    exec tio "$console" -b "$CONSOLE_BAUDRATE" -m INLCRNL
}

main() {
    parse_args "$@"
    select_mfg
    check_tooling
    check_build
    detect_port
    flash
    info "flash verified complete"
    if [ "$OPEN_CONSOLE" -eq 1 ]; then
        open_console
    fi
}

main "$@"
