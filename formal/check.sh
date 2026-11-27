#!/bin/sh
set -eu

usage() {
    printf '%s\n' 'Usage: formal/check.sh [all|formal|tla|lifecycle|startup|lean|boundaries|controller-boundary|kit-boundary]'
}

check_formal() {
    make -C formal/tla check
    make -C formal/lean check
}

check_controller_boundary() {
    python3 -B formal/boundaries/check_controller_boundary.py --negative-controls
    python3 -B formal/boundaries/check_controller_boundary.py
}

check_kit_boundary() {
    python3 -B formal/boundaries/check_kit_boundary.py
}

check_boundaries() {
    check_controller_boundary
    check_kit_boundary
}

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

CDPATH='' cd -- "$(dirname -- "$0")/.."
case "${1-all}" in
    all) check_boundaries; check_formal ;;
    formal) check_formal ;;
    tla) exec make -C formal/tla check ;;
    lifecycle) exec make -C formal/tla check-lifecycle ;;
    startup) exec make -C formal/tla check-startup ;;
    lean) exec make -C formal/lean check ;;
    boundaries) check_boundaries ;;
    controller-boundary) check_controller_boundary ;;
    kit-boundary) check_kit_boundary ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
