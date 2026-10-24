.text
.p2align 2
.macro H120_RANGE_FORWARD name, original
.globl _\name
_\name:
    adrp x16, _H120ActiveFPSBits@PAGE
    add x16, x16, _H120ActiveFPSBits@PAGEOFF
    ldar w17, [x16]
    cbz w17, 1f
    fmov s0, w17
    fmov s1, s0
    fmov s2, s0
1:
    adrp x16, _\original@PAGE
    ldr x16, [x16, _\original@PAGEOFF]
#if defined(__arm64e__)
    xpaci x16
#endif
    br x16
.endmacro

H120_RANGE_FORWARD H120RangeTimingsBB, H120OriginalRangeTimingsBB
H120_RANGE_FORWARD H120RangeTimingsB, H120OriginalRangeTimingsB
H120_RANGE_FORWARD H120RangeConvert, H120OriginalRangeConvert
H120_RANGE_FORWARD H120RangeSource, H120OriginalRangeSource
H120_RANGE_FORWARD H120RangeItemLocked, H120OriginalRangeItemLocked
H120_RANGE_FORWARD H120RangeItem, H120OriginalRangeItem
