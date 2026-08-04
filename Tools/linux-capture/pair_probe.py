"""Tight WHOOP 5 bonding probe: scan -> connect -> pair (just-works) -> test fd4b access.
Usage: python3 pair_probe.py <MAC>   (or set WHOOP_MAC). Use on a strap you own; phone BT off."""
import asyncio, os, sys, time
from bleak import BleakClient, BleakScanner
MAC = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("WHOOP_MAC", "")
if not MAC:
    sys.exit("usage: python3 pair_probe.py <MAC>   (or export WHOOP_MAC=AA:BB:CC:DD:EE:FF)")
HELLO = bytes.fromhex("aa0108000001e67123019101363e5c8d")
CMD = "fd4b0002-cce1-4033-93ce-002d5875f58a"
N3  = "fd4b0003-cce1-4033-93ce-002d5875f58a"

def log(*a): print(f"[{time.strftime('%H:%M:%S')}]", *a, flush=True)

async def main():
    log("scanning 6s for the strap…")
    dev = await BleakScanner.find_device_by_address(MAC, timeout=6)
    if not dev:
        log("NOT FOUND in scan — strap asleep / not advertising. Re-trigger pairing mode."); return
    log("found, connecting…")
    try:
        async with BleakClient(dev, timeout=12) as c:
            log("connected:", c.is_connected)
            # THE PAIR TEST
            t0 = time.time()
            try:
                ok = await asyncio.wait_for(c.pair(), timeout=15)
                log(f"pair() returned {ok} in {time.time()-t0:.1f}s")
            except asyncio.TimeoutError:
                log("pair() HUNG >15s (no SMP response from strap)"); return
            except Exception as e:
                log(f"pair() FAILED: {type(e).__name__}: {str(e)[:110]}"); return
            # If we got here, bond likely succeeded — prove it by touching fd4b.
            log("bond established — testing fd4b access…")
            frames = []
            try:
                await asyncio.wait_for(
                    c.start_notify(N3, lambda s,d: (frames.append(bytes(d)), log("  FRAME", bytes(d).hex()))),
                    timeout=8)
                log("subscribe fd4b0003: OK")
            except asyncio.TimeoutError:
                log("subscribe fd4b0003: still HUNG (bonded but encryption not applied?)")
            try:
                await c.write_gatt_char(CMD, HELLO, response=False)
                log("CLIENT_HELLO written (withoutResponse)")
            except Exception as e:
                log("CLIENT_HELLO write failed:", str(e)[:90])
            log("listening 10s for puffin frames…")
            await asyncio.sleep(10)
            log(f"TOTAL puffin frames: {len(frames)}")
    except Exception as e:
        log(f"connect FAILED: {type(e).__name__}: {str(e)[:110]}")

asyncio.run(main())
