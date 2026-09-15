#!/bin/sh
# =============================================================================
# freqtest.sh — 单线程等效频率自测（冷机 / 热机各跑一次对比）
#
# 用途：判断“降频”到底是温控压频，还是正常的 DVFS / 多核功耗预算。
#   冷机（刚开机或静置 5 分钟）跑一次，记下 best；
#   热机（跑满负载到电池 42℃+）再跑一次，记下 best；
#   两次 best 接近  -> 没有压频，之前看到的低 MHz 是多核 DVFS 正常行为；
#   热机 best 明显变慢（>10%）-> 确实被压频，且压频发生在内核/固件层
#                                （用户态能拦的写入插件已经拦了）。
#
# 用法：  sh freqtest.sh [轮数]        默认 5 轮
# 说明：  纯 Python，无依赖；每轮固定工作量，输出耗时，越小越快。
# =============================================================================
exec python3 - "$@" <<'PY'
import sys, time, ctypes, statistics

rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 5
OPS = 1500000

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)

def notify_state(name):
    """读取 Darwin notify 状态（热压等级等）；读不到返回 None"""
    token = ctypes.c_int(0)
    if libc.notify_register_check(name.encode(), ctypes.byref(token)) != 0:
        return None
    value = ctypes.c_uint64(0)
    if libc.notify_get_state(token, ctypes.byref(value)) != 0:
        return None
    return value.value

print("=== 热压信号 ===")
for name in ("com.apple.system.thermalnotification",
             "com.apple.system.thermalpressurelevel",
             "com.apple.system.thermalsunlightstate",
             "com.apple.system.maxthermalsensorvalue"):
    print("  %-42s = %s" % (name, notify_state(name)))

try:
    print("  %-42s = %s" % ("ProcessInfo.thermalState",
          __import__("objc").lookup_class("NSProcessInfo")))
except Exception:
    pass

print("=== 单线程基准（每轮 %d 次 64 位乘加，耗时越小越快）===" % OPS)
times = []
for r in range(rounds):
    t0 = time.perf_counter()
    a = 0x243F6A8885A308D3
    MASK = (1 << 64) - 1
    for _ in range(OPS):
        a = (a * 6364136223846793005 + 1442695040888963407) & MASK
        a ^= a >> 29
    dt = time.perf_counter() - t0
    times.append(dt)
    print("  round %d: %.3fs" % (r + 1, dt))

best = min(times)
med = statistics.median(times)
print("=== 结果 ===")
print("  best  = %.3fs   （与另一次运行的 best 比较）" % best)
print("  median= %.3fs" % med)
print("  提示：热机 best / 冷机 best > 1.10 说明确实被压频")
PY
