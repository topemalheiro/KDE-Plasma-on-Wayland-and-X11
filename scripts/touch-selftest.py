import os, re, select, struct, time, collections
FMT = "llHHi"; SZ = struct.calcsize(FMT)

# Resolve the touch nodes fresh -- they move on every re-enumeration.
nodes = {}
block = {}
for line in open("/proc/bus/input/devices"):
    line = line.rstrip()
    if not line:
        if "SiS HID Touch" in block.get("N", ""):
            m = re.search(r"event\d+", block.get("H", ""))
            phys = block.get("P", "")
            if m:
                port = "12.1" if "12.1" in phys else "13.3" if "13.3" in phys else "?"
                nodes[m.group(0)] = f"TOUCH {port}"
        block = {}
        continue
    if len(line) > 2 and line[1] == ":":
        block[line[0]] = line[3:]
nodes["event4"] = "CONTROL mouse"

fds = {}
for n in nodes:
    try:
        fds[os.open(f"/dev/input/{n}", os.O_RDONLY | os.O_NONBLOCK)] = n
    except OSError as e:
        print(f"CANNOT OPEN {n}: {e}", flush=True)

total = collections.Counter()
print(f"watching {', '.join(f'{k}={v}' for k,v in nodes.items())} for 20s", flush=True)
print("TOUCH BOTH SCREENS NOW", flush=True)
end = time.time() + 20
while time.time() < end:
    r, _, _ = select.select(list(fds), [], [], 1.0)
    for fd in r:
        try:
            data = os.read(fd, SZ * 128)
        except OSError:
            continue
        total[fds[fd]] += len(data) // SZ
print("\n=== RESULT ===", flush=True)
for n, label in nodes.items():
    print(f"  {n:<9} {label:<18} {total[n]:>7} events", flush=True)
