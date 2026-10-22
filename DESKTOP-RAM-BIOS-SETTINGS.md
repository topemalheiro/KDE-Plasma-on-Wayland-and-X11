# Desktop RAM BIOS Settings

ASUS ProArt Z790-CREATOR WIFI running four DDR5 sticks from two different kits. Use this after a CMOS clear, a BIOS update, or anything else that resets the BIOS.

> **Status, 22 Oct 2026:** these settings boot and the PC works normally. MemTest86 tests 1–6 passed in a partial run. Similar settings failed MemTest86 earlier the same day, before a CMOS clear, so finish a full 4-pass run (see [Test before trusting](#test-before-trusting)) and record the result here.

## Hardware

| Part | Details |
|---|---|
| Motherboard | ASUS ProArt Z790-CREATOR WIFI |
| CPU | Intel Core 14th gen, K model |
| RAM kit 1 | G.Skill Trident Z5 Neo RGB, 2 × 16 GB, DDR5-6000 CL30-38-38-96, 1.35 V (probably F5-6000J3038F16GX2-TZ5NR; check the sticker) |
| RAM kit 2 | G.Skill Aegis 5 (black), 2 × 16 GB, DDR5-6000 CL36-36-36-96, 1.35 V (F5-6000J3636F16GX2-IS) |

Each kit worked on its own when tested. The trouble only starts with all four sticks.

## Settings

Press **Del** at boot, then **F7** for Advanced Mode. Everything below is on the **Ai Tweaker** tab.

1. **Ai Overclock Tuner:** DOCP I (called XMP I with some kits). Set this first, because choosing it resets DRAM Frequency to 6000.
2. **DRAM Frequency:** DDR5-5867 (ASUS rounds 5866.67 up).
3. **DRAM Timing Control:** click each field, type the value, press Enter.

   | Setting | Value |
   |---|---|
   | DRAM CAS# Latency | 36 |
   | DRAM RAS# to CAS# Delay (Read and Write, if listed separately) | 38 |
   | DRAM RAS# PRE Time | 38 |
   | DRAM RAS# ACT Time | 96 |

4. Leave everything else on Auto. DOCP I sets **DRAM VDD Voltage** and **DRAM VDDQ Voltage** to 1.35 V by itself.
5. **Slots:** one kit in A2 + B2, the other kit in A1 + B1. From the CPU outward the slots are A1, A2, B1, B2; check the labels printed on the board.

Also redo after a reset:

- **Monitor → Q-Fan Configuration → CPU Fan Speed Low Limit → Ignore.** This stops the CPU fan warning at boot. Only do it while the CPU cooler's fan is connected and spinning.
- **Tool → ASUS User Profile:** save the finished settings to a profile, and to a USB stick. Next time, load the profile instead of typing everything in. Profiles may not survive a BIOS update, which is what the list above is for.

## Test before trusting

Unstable RAM can corrupt files without any warning, so test before using the PC normally.

1. After **F10**, hold **Del** so the PC goes back into the BIOS instead of booting the OS on untested settings.
2. **Tool → MemTest86:** run the full default test (4 passes). Any error counts as a fail.
3. If it passes, run about an hour of a memory stress test in the OS with the case warm.

## If MemTest86 fails

Change one thing at a time, then test again:

1. **DRAM Command Rate:** 2N (in DRAM Timing Control). Intel recommends 2N for mixed sticks.
2. **DRAM Frequency:** 5600.
3. **DRAM Frequency:** 5200.
4. Also set the refresh timings to the JEDEC values, which are safe for any DDR5 chip:

   | DRAM Frequency | DRAM REF Cycle Time | DRAM REF Cycle Time 2 | DRAM REF Cycle Time Same Bank |
   |---|---|---|---|
   | 5867 | 866 | 470 | 382 |
   | 5600 | 826 | 448 | 364 |
   | 5200 | 767 | 416 | 338 |

5. **One kit per channel:** one kit in A1 + A2, the other in B1 + B2. Switch off and unplug the PC before moving sticks.
6. **Ai Overclock Tuner:** Manual, **DRAM Frequency:** 4000 (Intel's rated speed for four sticks), DRAM VDD and DRAM VDDQ Voltage 1.35 V. If even this fails, suspect hardware and test each stick alone in slot A2.

Known-good fallback: one kit alone in A2 + B2 on DOCP I / XMP I (32 GB).

## Voltages

Don't raise voltages to fix this. Lower the frequency instead.

- **DRAM VDD / DRAM VDDQ Voltage:** 1.35 V, both kits' rating. G.Skill warns that voltage above the rating may damage modules over time.
- **IVR Transmitter VDDQ Voltage:** Auto. This is a CPU-side setting, not the same as DRAM VDDQ.
- **Memory Controller Voltage:** Auto. Common tuning values (1.30–1.40 V) are well above Intel's spec of 1.116 V ± 4.5%.
- **CPU System Agent Voltage:** Auto. If Auto shows more than 1.25 V, set 1.25 V; higher values can make some 13th/14th-gen CPUs unstable.
- **High DRAM Voltage Mode:** Disabled.

## If it won't boot

- With four sticks, memory training can keep the screen black for several minutes with the orange DRAM light on. Wait up to about 10 minutes before doing anything.
- If training fails, the board normally restarts on safe settings and shows "Overclocking failed". Press **F1** to enter the BIOS.
- If it's completely stuck: switch off, unplug, and short the 2-pin **CLRTC** header on the bottom edge of the board with a screwdriver for a few seconds. The board has no Clear CMOS button; the rear-panel button is BIOS FlashBack.
- If Windows asks for a BitLocker recovery key after a reset or BIOS update, get it from aka.ms/myrecoverykey.

## Why this is fiddly

- Four sticks means two per channel. Intel rates that at DDR5-4000 on 12th–14th gen and doesn't guarantee any speed when the sticks in a channel have different part numbers (datasheet 743844, DDR support matrix, note 7).
- ASUS and G.Skill both say not to mix kits, and G.Skill's compatibility lists cover single kits only.
- DOCP I / XMP I copies only CL, tRCD, tRP and tRAS from one kit's profile. The board picks every other timing itself.
- Stability with four sticks can change between BIOS versions. BIOS 3202 (August 2026) is the latest and lists improved memory compatibility.

## Sources

- Intel 13th/14th gen desktop datasheet, vol. 1: https://cdrdv2-public.intel.com/743844/743844-015.pdf
- ASUS Intel 700-series BIOS manual: https://dlcdnets.asus.com/pub/ASUS/mb/13MANUAL/PRIME_PROART_TUF_GAMING_INTEL_700_Series_BIOS_EM_WEB_EN.pdf
- ProArt Z790-CREATOR WIFI user manual: https://dlcdnets.asus.com/pub/ASUS/mb/LGA1700/ProArt_Z790-CREATOR_WIFI/E20704_ProArt_Z790-CREATOR_WIFI_UM_WEB.pdf
- G.Skill Aegis 5 specification: https://www.gskill.com/specification/165/440/1729563538/F5-6000J3636F16GX2-IS-Specification
