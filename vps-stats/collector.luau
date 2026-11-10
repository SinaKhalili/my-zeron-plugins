-- Read-only Linux collector, sent to python3 over the existing SSH connection.
return [==[
import json
import os
import socket
import time


def cpu_ticks(text):
    values = [int(v) for v in text.splitlines()[0].split()[1:9]]
    return sum(values), values[3] + (values[4] if len(values) > 4 else 0)


def memory_stats(text):
    values = {}
    for line in text.splitlines():
        key, _, rest = line.partition(":")
        if rest.strip():
            values[key] = int(rest.split()[0]) * 1024
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", values.get("MemFree", 0) + values.get("Buffers", 0) + values.get("Cached", 0) + values.get("SReclaimable", 0) - values.get("Shmem", 0))
    available = min(total, max(0, available))
    used = total - available
    swap_total = values.get("SwapTotal", 0)
    swap_used = max(0, swap_total - values.get("SwapFree", 0))
    return ({"total": total, "used": used, "available": available, "percent": used / total * 100 if total else None},
            {"total": swap_total, "used": swap_used, "percent": swap_used / swap_total * 100 if swap_total else 0})


def read(path):
    with open(path) as stream:
        return stream.read()


def interface_name():
    try:
        for line in read("/proc/net/route").splitlines()[1:]:
            fields = line.split()
            if len(fields) > 3 and fields[1] == "00000000" and int(fields[3], 16) & 1:
                return fields[0]
    except (OSError, ValueError):
        pass
    try:
        names = [line.split(":", 1)[0].strip() for line in read("/proc/net/dev").splitlines()[2:]]
        return next((name for name in names if name.startswith(("eth", "ens", "enp", "eno"))), None)
    except OSError:
        return None


def network_bytes(interface):
    if not interface:
        return None
    try:
        for line in read("/proc/net/dev").splitlines()[2:]:
            name, _, rest = line.partition(":")
            if name.strip() == interface:
                fields = rest.split()
                return int(fields[0]), int(fields[8])
    except (OSError, ValueError, IndexError):
        pass
    return None


def collect(disk_path):
    started = time.monotonic()
    first_cpu = cpu_ticks(read("/proc/stat"))
    interface = interface_name()
    first_net = network_bytes(interface)
    memory, swap = memory_stats(read("/proc/meminfo"))
    vfs = os.statvfs(disk_path)
    block = vfs.f_frsize or vfs.f_bsize
    total, used, free = vfs.f_blocks * block, (vfs.f_blocks - vfs.f_bfree) * block, vfs.f_bavail * block
    inode_used = max(0, vfs.f_files - vfs.f_ffree)
    inode_available = max(0, vfs.f_favail)
    inode_denominator = inode_used + inode_available
    disk = {"path": disk_path, "total": total, "used": used, "available": free,
            "percent": used / (used + free) * 100 if used + free else None,
            "inodePercent": inode_used / inode_denominator * 100 if inode_denominator else None}
    uptime = float(read("/proc/uptime").split()[0])
    load = list(os.getloadavg())
    processes = sum(name.isdigit() for name in os.listdir("/proc"))
    time.sleep(max(0, 0.3 - (time.monotonic() - started)))
    second_cpu = cpu_ticks(read("/proc/stat"))
    second_net = network_bytes(interface)
    duration = max(0.001, time.monotonic() - started)
    total_ticks = second_cpu[0] - first_cpu[0]
    idle_ticks = second_cpu[1] - first_cpu[1]
    cpu = min(100, max(0, (total_ticks - idle_ticks) / total_ticks * 100)) if total_ticks > 0 else None
    network = {"interface": interface, "down": None, "up": None}
    if first_net is not None and second_net is not None:
        network.update(down=max(0, second_net[0] - first_net[0]) / duration, up=max(0, second_net[1] - first_net[1]) / duration)
    return {"host": socket.gethostname(), "at": time.time(), "cpu": cpu, "cores": os.cpu_count() or 1,
            "memory": memory, "swap": swap, "disk": disk, "network": network,
            "load": load, "uptime": uptime, "processes": processes, "sampleSeconds": duration}


if __name__ == "__main__":
    try:
        print(json.dumps(collect(DISK_PATH), allow_nan=False))
    except FileNotFoundError:
        print(json.dumps({"error": "Disk path or Linux system metrics are unavailable."}))
    except Exception:
        print(json.dumps({"error": "Could not read system metrics on this host."}))

]==]
