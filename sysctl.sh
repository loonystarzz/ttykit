# ── track Meta (Super) key held state ─────────────────────────────────────────
_meta_held = False

async def read_device(dev):
    global _meta_held
    async for event in dev.async_read_loop():
        if event.type != ecodes.EV_KEY:
            continue
        key = categorize(event)

        # track Meta (Super / Windows key) held state
        if event.code in (ecodes.KEY_LEFTMETA, ecodes.KEY_RIGHTMETA):
            _meta_held = (key.keystate != key.key_up)
            continue

        if key.keystate == key.key_down:
            # Meta + 1-4 → workspace switch
            if _meta_held and event.code in WS_KEYS:
                num = WS_KEYS[event.code]
                threading.Thread(target=ws_switch, args=(num,), daemon=True).start()
                continue

            # regular mapped keys (media keys etc.)
            action = KEY_MAP.get(event.code)
            if action:
                try:
                    action()
                except Exception as e:
                    log(f"error handling key {event.code}: {e}")
