#!/usr/bin/env bash
#
# Regression test: a button released over a layer surface must reach that surface,
# even when root.buttons binds the same button.
#
# The press path already left layer-surface clicks alone, but the release path
# didn't look for layer surfaces, so it treated them as empty desktop. A root
# binding for the button (the default rc binds 3 to the main menu) then swallowed
# the release, the surface never saw the button go up, and bars ignored every
# later right-click.
#
# root.fake_input delivers buttons straight to the seat, skipping that code, so
# this drives real pointer input: a headless "outer" somewm hosts an "inner"
# somewm on the Wayland backend and clicks into its window.
# Needs two compositors, so it is a process-level test rather than Lua/IPC.
#
# Usage: ./tests/test-layer-button-release.sh [somewm] [somewm-client] [test-layer-client]

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOMEWM="$(realpath "${1:-./build-test/somewm}")"
CLIENT="$(realpath "${2:-./build-test/somewm-client}")"
LAYER_CLIENT="$(realpath "${3:-./build-test/test-layer-client}")"

TMP_DIR="$(mktemp -d)"
mkdir -m 700 "$TMP_DIR/runtime"
mkdir -p "$TMP_DIR/config/somewm"
cp "$ROOT_DIR/tests/rc.lua" "$TMP_DIR/config/somewm/rc.lua"

export WLR_RENDERER=pixman
export NO_AT_BRIDGE=1
export XDG_RUNTIME_DIR="$TMP_DIR/runtime"
export XDG_CONFIG_HOME="$TMP_DIR/config"
export LUA_PATH="$ROOT_DIR/lua/?.lua;$ROOT_DIR/lua/?/init.lua;$ROOT_DIR/tests/?.lua;${LUA_PATH:-};"
unset DISPLAY WAYLAND_DISPLAY SOMEWM_SOCKET

OUTER_PID="" INNER_PID="" LAYER_PID=""
cleanup() {
    kill -KILL $LAYER_PID $INNER_PID $OUTER_PID 2>/dev/null
    rm -rf "$TMP_DIR"
    return 0
}
trap cleanup EXIT INT TERM

fail() {
    echo "--- FAIL: $1"
    for l in outer inner layer; do
        echo "Last 20 lines of $l log:"
        tail -20 "$TMP_DIR/$l.log" 2>/dev/null | sed 's/^/    /'
    done
    exit 1
}

wait_for() {
    local i
    for i in $(seq 150); do [ -e "$1" ] && return 0; sleep 0.1; done
    fail "timed out waiting for $1"
}

outer() { SOMEWM_SOCKET="$TMP_DIR/outer.sock" "$CLIENT" eval "$1" | sed -n 2p; }
inner() { SOMEWM_SOCKET="$TMP_DIR/inner.sock" "$CLIENT" eval "$1" | sed -n 2p; }

SOMEWM_SOCKET="$TMP_DIR/outer.sock" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    "$SOMEWM" >"$TMP_DIR/outer.log" 2>&1 &
OUTER_PID=$!
wait_for "$TMP_DIR/outer.sock"
wait_for "$XDG_RUNTIME_DIR/wayland-0"

SOMEWM_SOCKET="$TMP_DIR/inner.sock" WAYLAND_DISPLAY=wayland-0 WLR_BACKENDS=wayland \
    "$SOMEWM" >"$TMP_DIR/inner.log" 2>&1 &
INNER_PID=$!
wait_for "$TMP_DIR/inner.sock"
wait_for "$XDG_RUNTIME_DIR/wayland-1"

# Pin the inner's window at the outer's origin, so both share coordinates.
for i in $(seq 50); do
    [ "$(outer 'return #client.get()')" = 1 ] && break
    sleep 0.1
done
# IPC eval is line-based, so each snippet must be a single line.
outer 'local c = client.get()[1] c.floating = true c.border_width = 0 c:geometry({ x = 0, y = 0, width = 640, height = 360 })' >/dev/null
for i in $(seq 50); do
    [ "$(inner 'return screen[1].geometry.width')" = 640 ] && break
    sleep 0.1
done

# Root binding for button 3 that counts presses/releases, like the default rc's menu.
inner 'root_hits = 0 root.buttons(require("awful").button({}, 3, function() root_hits = root_hits + 1 end, function() root_hits = root_hits + 1 end))' >/dev/null

WAYLAND_DISPLAY=wayland-1 "$LAYER_CLIENT" --keyboard none --anchor top \
    >"$TMP_DIR/layer.log" 2>&1 &
LAYER_PID=$!
for i in $(seq 50); do
    [ "$(inner 'return #layer_surface.get()')" = 1 ] && break
    sleep 0.1
done
geo="$(inner 'local g = layer_surface.get()[1].geometry return math.floor(g.x + g.width / 2) .. " " .. math.floor(g.y + g.height / 2)')"
read -r lx ly <<<"$geo"
[ -n "${ly:-}" ] || fail "no layer surface in the inner compositor (got: $geo)"

# Right-click the layer surface twice. Each fake button is followed by motion, so
# the outer sends a pointer frame and the inner's Wayland backend dispatches it.
outer "mouse.coords({ x = $lx, y = $ly }) mouse._fake_motion(1, 0)" >/dev/null
sleep 0.3
for _ in 1 2; do
    for ev in button_press button_release; do
        outer "root.fake_input('$ev', 3) mouse._fake_motion(1, 0) mouse._fake_motion(-1, 0)" >/dev/null
        sleep 0.2
    done
done

# Nested delivery to the client can trail by an event, so don't count clicks: the
# bug's signature is a press with no release (wlroots then drops later presses).
presses="$(grep -c 'button 273 pressed' "$TMP_DIR/layer.log")"
releases="$(grep -c 'button 273 released' "$TMP_DIR/layer.log")"
[ "$presses" -ge 1 ] || fail "layer surface saw no right-button press"
[ "$releases" = "$presses" ] ||
    fail "layer surface saw $presses right-button presses but $releases releases"
hits="$(inner 'return root_hits')"
[ "$hits" = 0 ] || fail "root binding fired $hits times for clicks on a layer surface"

# Control: on empty desktop the same binding still gets its press and release.
outer "mouse.coords({ x = $lx, y = 300 }) mouse._fake_motion(1, 0)" >/dev/null
sleep 0.3
for ev in button_press button_release; do
    outer "root.fake_input('$ev', 3) mouse._fake_motion(1, 0) mouse._fake_motion(-1, 0)" >/dev/null
    sleep 0.2
done
hits="$(inner 'return root_hits')"
[ "$hits" = 2 ] || fail "root binding fired $hits times on empty desktop, expected 2"

echo "--- PASS: layer surface got a release for every right-button press; root binding only fired on the desktop"
echo "PASS"
exit 0
