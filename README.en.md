# PJDV M39 · iPadOS / iOS / macOS preview

[简体中文](README.md) | **English**

**Build 19 lightweight preview, October 29, 2026:** Adds an in-app GameBanana browser, streamed ZIP extraction/CRC validation and download retry. Two actual downloads were imported by the App and remain inactive. Offline converters were used for isolated model/song trials; Electric Angel NORMAL completed, as did X Song's Strangers and Umiyuri Kaiteitan. **Only selected model/song samples were tested; compatibility is not universal. Calc's inverted MV remains unresolved, and X Charts' New Classics mechanics are not integrated.** [Report and screenshots](Reports/MOD-DOWNLOAD-CONVERSION-20261029.md) · [Local converters](Tools/pc_mods/README.md)

**Historical Build 18 verification, October 25, 2026:** The launcher now offers MOD Manager (Experimental) for structural inspection and source registration of ZIP/ZIP64 or extracted folders. Extract 7z/RAR first. MODs are not copied, extracted or loaded. Mac UI flows and all three platform builds passed; the iPad device entry remains untested.

**Retained build 17 improvements:** AutoPlay workload testing, hardware diagnostics and hot-switch recovery; see the final build17 section for measured scope. retains build 15's native Touch Play fixes for rapid repeated touches and out-of-order snapshots, plus layout editing for all 18 virtual controls. Adds an M4 device research path for ProMotion 60→120: the source game remains at 60 FPS, real and generated frames are counted separately, and actual drawable presentations are measured. Normal launches still default to native 60 FPS. Stage screens, hair outlines and rhythm-game timing under interpolation have not passed acceptance testing. Research mode no longer hides advanced resolutions or forces ordinary 1080p scaling; both real and generated frames can use MetalFX Spatial. **1440p and screen-matched output require an M3 or newer Mac/iPad with Apple GPU family 9+. iPhone and family 7/8 devices remain capped at 1080p in build 17.** The reported 40–50 FPS in “39みゅーじっく！” on M1 still needs testing on that device. Reduced power consumption through interpolation is not established.

An Apple Silicon compatibility-port research project for the **Japanese Switch v1.0.9** release of *Hatsune Miku: Project DIVA MEGA39’s*. The original ARM64 program runs through a Horizon service compatibility layer, with **NVN → Metal** graphics output.

**0.1.5, build 18 · validation preview · October 25, 2026.** Releases contain lightweight installers only, without game assets, keys or personal saves. Full packages are no longer produced automatically.

**Build 10 import changes, October 22:** the importer recognizes content belonging to MEGA39’s Title ID `0100F3100DA46000`. It no longer requires fixed NCA filenames, v1.0.9 resource fingerprints or exactly 27 DLC entries. CNMT metadata determines the update, the actual DLC set and complete language resources. Existing difficulties and costumes included in the imported content are unlocked. Unsupported language choices fall back to Japanese.

The runtime still uses the adapted JP v1.0.9 program; it does not execute arbitrary NSOs from a newly imported XCI. Removing import version restrictions does **not** establish runtime compatibility with every resource version or other regional executables. The launcher flags unknown resource versions as unverified. New imports record their contents in `game-content.json`; existing v1.0.9 folders remain supported. Separate ticket/TitleKey encryption needs further work. Missing required keys, conflicting updates and incomplete packages stop the import without modifying the source XCI.

[Latest build 19 preview](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/v0.1.5b19) · [Build 18](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/v0.1.5b18) · [Build 17](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/v0.1.5b17) · [Build 14](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/v0.1.5b14) · [Build 10](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/v0.1.5b10) · [Original build 7](https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/v0.1.5) · [Installation guide](#choosing-an-installer)

[Demo video on bilibili](https://www.bilibili.com/video/BV1KGni6YEZd/)

**Known compatibility gaps:** base v1.0.0 resources can be imported and reach rhythm gameplay, but their 3D PVs remain black and some help images are missing. JP v1.0.9 is the recommended resource baseline. macOS 11 is a deployment target, not a completed Big Sur/M1 hardware qualification. Presentation-rate accounting on the classic drawable fallback still needs verification.

## 0.1.5 changes and validation scope

- **Lower deployment requirements:** iOS/iPadOS 17.0+, Apple GPU family 7 minimum (the A14/M1 generation), including iPhone. iOS uses the standard Metal command-queue submission path. Build 10 lowers the Mac deployment target to M1/macOS Big Sur 11; actual older-system qualification remains pending.
- **Native touch and layouts, builds 15/16:** rapid reuse of a touch ID no longer merges a new press into an older touch. Cross-thread snapshots are published in revision order. All 18 virtual controls can be moved and scaled individually; shoulder buttons retain their aspect ratio. Layouts are saved per device profile. Turn off the virtual controller when testing native Touch Play so its button regions do not intercept touches.
- **Lower GPU tier, families 7/8:** first launch defaults to 720p/standard quality, with a 1080p output cap. HDR, ray tracing and 60→120 are disabled. MetalFX Spatial is offered according to actual device support. Lower-tier resolution and quality preferences are separate; old high-tier settings cannot bypass the cap.
- **Standalone simulator 30→60 experiment:** an iPhone 18 Pro/iOS 27.2 synthetic scene passed midpoint readback, on/off comparison, scene-cut, pause/resume and re-entry checks. With no MetalFX framework in that simulator, it uses an explicitly identified fallback algorithm. This is neither a real-game test nor qualification of Apple's frame interpolation. The standalone experiment requires iOS 26. A real-game interpolation research path exists from build 9, but its image quality has not passed acceptance testing; it remains unavailable during normal build 10/16 launches.

**This is a compatibility preview.** iOS, Simulator and Mac builds pass. A forced family 7 profile on the iPhone 18 Pro simulator displays the introduction, title and main menu at 720p/1080p. **Actual iOS 17, M1/A14 devices have not been qualified.** Stability on 4 GB devices, all-song performance, and HDR/RT regression on the revised iOS Metal 3 submission path remain unverified. A roughly 60 FPS simulator menu is not a performance measurement for older hardware.

## Recent improvements

- **Scenes and depth of field:** corrected alpha control flow in two fragment shaders and the NVN-to-Metal depth-range conversion. Sampled “39みゅーじっく！” shots regained cube surfaces, luminous rings, screen content and character focus. This does not establish complete lighting or all-song visual fidelity.
- **Loading:** the base game and 27 DLC packages share a native FARC/gzip decoding path. Content verification passed for 477,748 compressed entries. Benefits depend on each song's resources; instant loading for every song is not guaranteed.
- **Self-contained rendering dependencies:** lightweight packages include matching Metal shaders and reflection caches. Imported resources do not depend on the developer machine's cache directories.
- **Experimental iPhone support:** devices meeting Apple GPU family 7 requirements are eligible for the compatibility preview. Build 16 caps output at 1080p/60 FPS and hides 1440p, screen-matched and 120 FPS options. Phone and folding layouts were initially checked in the simulator.
- **Folding layouts:** expanded mode centers the game; closed mode uses landscape; tabletop mode separates the upper game area from the lower controller. Original proportions are retained, with system status indicators using the natural letterbox area. Simulator support is not qualification of physical folding hardware.
- **All virtual controls:** before starting the game, open **Virtual controls: size & position** on the launcher (called **Virtual controller layout** in build 16 and earlier). Resize and move any of the 18 buttons/sticks. Phone, tablet and folding profiles save separately; folding profiles have smaller default sticks.
- **Language matching:** selecting Japanese, Simplified Chinese or Traditional Chinese sets both host and game to that language. Finding an English string table does not establish complete English menus: this JP package mixes in Japanese menu images, so English and Korean choices are currently hidden. Previously saved selections for those languages fall back to Japanese. Some low-level diagnostics retain technical text.
- **Controller glyphs:** the physical controller type can select in-game glyphs. Xbox melody previews use **Y, X, A, B in up, left, down, right order**. PlayStation reuses the original symbol assets; arrow mode and existing input mappings remain intact. Diagnostic Xbox glyph selection on M4 iPad verified menu/settings footers, the YXAB preview and button settings. This round did not connect a physical Xbox controller; hot-plug detection and complete charts need more testing. Some baked help images, the title's “Press A” prompt and the central controller diagram still show original artwork.

## Hardware support and graphics options

| Item | Current status |
| --- | --- |
| OS | iOS/iPadOS 17+; build 10 targets M1/macOS Big Sur 11+ through Mac Catalyst 14. Actual iOS 17/Big Sur startup still needs corresponding hardware testing. |
| GPU | Apple GPU family 7+ (A14/M1 generation). Families 7/8 use the lower tier; actual performance is unqualified. |
| iPhone | Experimental; maximum1080p, default native60. build17 allows60→120 research on family9+ devices with an actual120Hz display; phone rhythm regression is pending. |
| iPad/Mac | Lower tier: up to 1080p. M3 or newer Mac/iPad with family 9+: 1440p or screen-matched output. The game retains a 16:9 aspect ratio. |
| MetalFX Spatial | Integrated into game output scaling, including its UI. This is neither native high-resolution 3D rendering nor temporal reconstruction. |
| Game HDR mapping | Disabled on the lower tier. Experimental and off by default on family 9+. Expands highlights from the original floating-point scene while retaining the SDR tonal baseline; assets are not native HDR. Independent EDR output and a character-scene sample passed on M4 in 0.1.4. The revised iOS Metal 3 path, UI protection and more songs still need device/frame comparisons. |
| 30→60 / 60→120 | Real-game research uses an image optical-flow algorithm, **not MetalFX frame interpolation**, and defaults to off, with explicit menu opt-in. M4 ProMotion has shown source60 + generated60 and about 120 actual presentations/s. Visual quality and rhythm timing remain unqualified. Standalone MetalFX frame interpolation requires iOS/Mac Catalyst 26. The lower tier has no120FPS; build17 permits60→120 on eligible120Hz family9+ iPhones. |
| Ray tracing | Disabled on the lower tier. Experimental single-light, opaque-stage shadows require family 9+ and the actual ray-tracing APIs. Off by default; this is not global illumination or full character ray tracing. |
| Audio | AudioRenderer → CoreAudio, 48 kHz stereo. Introduction, menu and song audio have been tested. |
| Input | Switch-layout virtual controller, keyboard, DualSense and Xbox. Connecting a physical controller automatically hides the virtual pad; it can also be toggled manually. |
| Rumble | A user confirmed DS5 continuous long-slide feedback in “Catch the Wave” on hardware. Ordinary short slides do not establish that the same vibration event occurred. |
| Unlocked content | All existing difficulties, costumes and accessories in the installed content are initially available. Scores and settings are preserved; the original save is backed up before modification. |
| Exit | Only the original eShop entry is remapped to “Exit game.” Confirmation saves and shuts down the session. |
| Monitoring | Floating FPS, CPU and RAM display. Simulator rates and sustained device performance are evaluated separately. |

The public build 7 baseline is **JP v1.0.9 / 589824, Title ID 0100F3100DA46000, one base game + one update + 27 DLC**. Build 10 removes filename, version-number and DLC-count restrictions for imports with the same Title ID; other regional programs and resource versions require separate runtime validation. Full visual fidelity across every song/costume, audiovisual synchronization and sustained real 60 FPS remain under investigation.

## Choosing an installer

| Package | Purpose |
| --- | --- |
| GitHub iOS IPA, iPad/iPhone | Lightweight and unsigned. Sign it with your own valid identity and import your own game and keys. |
| GitHub Mac DMG | Lightweight arm64 application, ad hoc signed and not notarized. Import your own resources before playing. |

Public packages contain no XCI, extracted game payload, `prod.keys`, personal saves or local development-signing configuration. Select your own keys locally during import. Following the October 24 cleanup request, this working project's obsolete large integrated archives and full-package staging directories have been removed. The original XCI, current extracted resources, save backups and lightweight installers were retained. Future automatic packaging is lightweight only.

## Installing on iPad and launching for the first time

1. Sign the IPA with your own valid development identity and install it on an authorized iPad/iPhone. The public IPA is unsigned; copying it into Files does not install the application.
2. Enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) when required by the OS. If asked to trust a developer, use **Settings → General → VPN & Device Management** for the corresponding identity.
3. Open PJDV M39 and import an XCI or connect prepared resources using the methods below. **Start game** stays disabled until resources are ready.
4. Select **Start game**. Use virtual A, keyboard D or the physical controller's confirm button. A can skip the opening movie.

Private development signatures have an expiration date and cover only registered devices; a different iPad needs a suitable signature. Prefer installing updates over the existing app. Back up saves before uninstalling.

**Version note:** build 14 includes root-folder auto import, the folder-picker fallback and the import-memory fix. Historical build 10 does not include these newer entry points.

### Method 1: automatic import from the app root, build 13+

1. Open the installed app at least once. In Files, go to **On My iPad/iPhone → PJDVM39** (the OS may display **PJDV M39**). This is the app's exposed Documents root.
2. Copy your unarchived MEGA39’s `.xci` and your own `prod.keys` into that root, alongside each other:

   ```text
   PJDVM39/
   ├── MEGA39s.xci       # The filename can differ; use the .xci extension.
   ├── prod.keys
   └── GameResources/   # Created by the importer.
   ```

3. Wait until Files/Finder finishes copying. Return to PJDV's **launcher** and keep it in the foreground. Every two seconds it checks the root. Once file sizes and modification times have remained unchanged for at least four seconds, it opens resource management, validates the keys, and begins XCI preflight/extraction.
4. Wait for **Import complete**, then choose **Done → Start game**. A keys-only batch saves the keys first. If valid local keys are already stored, a later XCI can be imported on its own.

You can also use **Finder → iPad/iPhone → Files → PJDV M39** to copy both files to the app root. XCI filenames are flexible; contents must still have the supported MEGA39’s Title ID `0100F3100DA46000`.

- Only regular `.xci`/`.keys` files directly in the root are detected. Source files inside `GameResources` or other subfolders do not trigger automatic import.
- Multiple XCI/key candidates open an app-owned selection list. Extract ZIP/7z archives first; fully download cloud files before importing.
- Four seconds of stable metadata only allows inspection to begin; it does not prove that a large copy has finished. A truncated file or integrity failure stops the import. Once copying finishes, use **Detect XCI/keys in the app root** in resource management to retry.
- Successfully imported batches are not imported again on the next launch. The app does not scan during gameplay or import in the background.

### Method 2: choose an XCI manually, including external drives

1. Open **Import XCI / Resource management**. On first use, select **Choose/change prod.keys** and choose your own keys. Skip this step if valid keys are already stored.
2. Select **Import XCI** and choose the MEGA39’s `.xci`. The source can remain on an external drive.
3. Keep the app in the foreground until base resources, the selected update merge and the actual included DLC finish importing. Then select **Done → Start game**. Keep an external drive connected throughout the import.

### Method 3: folder fallback when tapping files does nothing, build 13+

Use this if the system picker shows files but tapping an XCI/key does not close the window or select it:

1. Open resource management and choose **Fallback: choose keys from a folder**.
2. Navigate to the containing folder in the system picker and select **Open**. Then choose the `.keys` file in the **app's own file list**.
3. Repeat with **Fallback: choose XCI from a folder**, opening the containing folder before selecting the `.xci` in the app list.

This authorizes access to the containing directory, then reads the selected source file directly. M1/iPadOS 18 users can prioritize this route or root-folder auto import for retesting. The fix is not yet confirmed on that reported device.

### Import progress, storage and retry

From build 13, preflight shows the current phase and an activity indicator. Once total resource size is known, it shows **percentage and completed/total bytes**. **Read/write rates, cumulative bytes and elapsed time** refresh every 0.5 seconds. Reads include XCI data and verification of existing resources; writes count successfully written resource data. Verified files reused during resume do not inflate write totals. These application-level rates include caching and are not physical-SSD benchmarks.

The source XCI stays where you selected it. It is not moved or copied in full before extraction; keys placed in the root also remain there. Extracted data goes separately into `GameResources` and needs additional storage. The tested v1.0.9 + 27 DLC set produces about **41.94 GB** of resources. Reserve **45 GB** for output, plus about **42.72 GB** if you also keep that source XCI on the device.

Cancellation retains completed work; choosing the same XCI again can resume. Insufficient space, a disconnected drive, integrity failure or a conflicting destination resource version produces an error while preserving the source and existing resources. Retry with **Detect XCI/keys in the app root** or select the XCI again manually.

### Method 4: connect existing extracted resources

A device that already has complete resources normally needs only the IPA update, not another resource transfer.

1. Prepare your own complete, successfully imported `GameResources` folder.
2. Install/open the app once. Connect the iPad to your Mac and copy the whole folder using **Finder → iPad → Files → PJDV M39**.
3. Wait for the transfer to finish. In resource management, select **Use resources already copied to this device**. You may also connect a prepared resource directory through Files.

Keep all preparation manifests and the directory structure. Copying only `rom` is insufficient:

```text
PJDV M39 Documents/
└── GameResources/
    ├── game-content.json       # Written by build 10+ imports; optional for old v1.0.9 folders.
    ├── romfs/                 # The legacy name MEGA39-v1.0.9 is also accepted.
    │   ├── preparation.json
    │   ├── complete.json
    │   ├── files.jsonl
    │   ├── rom/
    │   ├── rom_switch/
    │   ├── shader/
    │   └── ...
    └── DLC/
        ├── manifest.json
        ├── 1/
        ├── 2/
        └── ...                # Example only: follow manifest.json; do not renumber.
```

Prepared resources can remain on an external drive if it stays connected during play. Copy the complete directory locally first if you want local-storage access.

### If import crashes or stalls, build 14+

The importer shows current process memory and its sampled peak. “7 GB written” describes processed resources, **not 7 GB of RAM consumption**. Every five seconds it saves progress, I/O totals and memory samples to `PJDV-import-diagnostics.jsonl` in the app root. A retry retains the previous session as `PJDV-import-diagnostics.previous.jsonl`. These logs stay local and contain no key values, game-file paths or personal saves.

If the app still exits, retain both small logs and the corresponding `JetsamEvent` or PJDV crash report from **Settings → Privacy & Security → Analytics & Improvements → Analytics Data**. Device RAM capacity alone cannot determine why the process terminated. M1/iPadOS 18 needs direct retesting. Do not delete the source XCI or personal saves merely to retry.

## Mac installation and import

- Open the lightweight DMG and drag PJDV M39 into Applications or another permanent location. Import game resources separately.
- The app is ad hoc signed and not Apple-notarized. Review and approve this app according to [Apple's instructions for unnotarized applications](https://support.apple.com/102445).
- In resource management, choose your own `prod.keys`, then the XCI, then the resource destination. An external SSD is supported; the app remembers the location after import.
- To use existing resources, select **Connect extracted resource folder** and choose the parent containing both `romfs` (or `MEGA39-v1.0.9`) and `DLC`.
- Keep an external resource drive connected while playing. Reselect its folder if saved access is no longer valid.

## Keyboard mappings

Mac keyboards and iPad Magic Keyboard/external keyboards share these fixed physical QWERTY mappings. There is currently no remapping panel.

| Keyboard | Switch input |
| --- | --- |
| W | X, upper face button |
| A | Y, left face button |
| D | A, right face button / confirm |
| S | B, lower face button / back |
| Arrow keys ↑ / ↓ / ← / → | D-pad up / down / left / right |
| I / K / J / L | D-pad up / down / left / right |
| Q / E | L / R |
| Space | Press/release X, Y, A and B together |
| Delete / Backspace, including Forward Delete, or P | + / pause |
| Enter / Return, including keypad Enter, or M | − |

**Return does not confirm; use D to confirm.** ZL/ZR and both sticks have no keyboard mappings and are not keyboard-editable. Holds and chords are supported. Focus loss clears held input.

## Controller and touch testing

- **DualSense:** circle maps to Switch A/confirm; cross maps to Switch B/back. A user has checked basic D-pad, stick, four-face-button and L1/R1 operation.
- Test game rumble with successfully judged continuous long slides in **“Catch the Wave.”** Suitable chains occur around 1.7 seconds into EXTREME and 26.7 seconds into HARD. Ordinary short-slide taps do not verify this feedback path.
- Rumble is an approximate GameController/CoreHaptics translation, not bit-accurate Switch HD Rumble. Reconnection, left/right feedback and latency need more regression testing.
- The DS5 built-in speaker is unsupported on Mac/mobile; game audio plays through the device or headphones. See [Sony's controller support page](https://www.playstation.com/en-us/support/hardware/pair-dualsense-controller-bluetooth/).
- The virtual pad uses a Switch layout at a current default scale of 200%. It automatically hides when a physical controller connects and can also be toggled manually.
- Navigate original menus with direction/confirm buttons. Not every menu label is a direct touch target. Native Touch Play and virtual-button touch are separate test cases.
- **Builds 15/16:** on the launcher, open **Virtual controller layout** (renamed **Virtual controls: size & position** in the next candidate). Select any face button, D-pad direction, shoulder button, +/−, L3/R3 or stick. Resize with the slider or +/- steps; drag it, or select it and tap empty space to reposition. Save to apply; Cancel preserves saved settings. The 40–150% range is relative to the current default control size.
- For native Touch Play, disable the top **Virtual controller** toggle first. This clears virtual button state and lets native game regions receive touches. Host widgets, including the performance window, still own their actual UI regions.
- For M1 retesting, begin with native 60, 720p/standard quality. Record rapid taps, simultaneous two-finger input, hold/release and pause/resume separately. Retain `PJDV-runtime.log` from the app data directory. Development diagnostics with `PJDV_PERF_TRACE=1` additionally produce `PJDV-benchmark.jsonl`. Include the song, difficulty, shot and quality settings with feedback.

## Suggested test sequence

1. Cold launch, skip the introduction and open song selection. Check EXTREME/EX EXTREME and direct costume selection; verify that existing scores remain intact.
2. Use “Catch the Wave” for input and long-chain rumble. Test pause/resume, retry, return to selection, and controller disconnect/reconnect.
3. Use **“ゴーストルール” (Ghost Rule)** for sustained load. Compare ordinary scaling with MetalFX; record visual quality, stutters, frame times, synchronization and temperature.
4. Use **Exit game**, confirm saving, then relaunch and check for black screens, lingering audio, crashes and save integrity.

Earlier M4 iPad testing included three 1080p runs and multiple 1440p runs of Ghost Rule. Normal-play samples were around 60 FPS, with occasional longer intervals and loading stalls. This does not establish sustained real 60 FPS on every song/device. The FPS overlay alone cannot establish long-term frame pacing, thermals or audiovisual synchronization.

## Saves and logs

| Platform | Location |
| --- | --- |
| iPad | App `Documents/GuestSave` and `Documents/PJDV-runtime.log`, accessible through file sharing |
| Mac | `~/Library/Application Support/PJDVM39/GuestSave` and `PJDV-runtime.log` in the same parent directory |

The first pre-unlock save backup is `GuestSave.unlock-backup-v1/sys.dat`. Keeping a backup of the complete `GuestSave` directory is preferable. Do not replace `sys.dat` with a file from a different game/version. Early Mac test saves remain at their original Documents location; the local migration retained a copy. Other older installations can manually copy their saves to the new location while the app is closed.

## Validation and known issues

- The native XCI decryptor completed IVFC verification of all **41,943,373,493 bytes** of selected file data in the tested XCI. Every extracted file matched the earlier Python extraction's SHA-256. Directory fingerprints, file counts and byte totals agreed across 28 partitions.
- Missing-file repair, verification/reuse of existing resources, cancellation/resume, format boundaries and invalid-input rejection have been tested. The runtime remains the adapted program; it does not read and execute new program code from the imported XCI.
- Mac import through the system picker and restoration of folder access after relaunch passed. M4 iPad completed a full XCI import after a clean reinstall in build 14, as detailed below. The reported M1/iPadOS 18 device, additional external drives and other Files providers still need separate retesting.
- Default unlocking was checked with a fresh save and an existing M4 save, including device spot checks of EXTREME/EX EXTREME and costume equipping. Every individual song/difficulty/costume has not been played through.
- All-song image quality, reflection/lighting fidelity, Touch Play, more controllers, sustained real 60 FPS, heat and audio/judgment synchronization remain under validation.

See [BUILDING.md](BUILDING.md) for source preparation and engineering limitations. An English README does not add complete English in-game menu assets to the JP game package.

## References and credits

Main engineering references: [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile) and [jiayx/d2r-mobile-build](https://github.com/jiayx/d2r-mobile-build). Shader translation draws on the Ryujinx translation chain. Data research references include [MikuMikuSwitchPlugin](https://github.com/lsmsmx/MikuMikuSwitchPlugin), [ReDIVA](https://github.com/korenkonder/ReDIVA) and [hactool](https://github.com/SciresM/hactool). Dependency licenses and attribution are retained in the packaged `ThirdPartyNotices.txt`.

This is unofficial compatibility research. The game, characters and original assets belong to their respective rights holders. Public test packages require the user's own game and keys.

## Historical 0.1.4 validation

These are historical 0.1.4 results, not qualification of the revised 0.1.5 submission path.

- Release builds passed for iOS hardware, Simulator and Mac Catalyst. Output caps, folding-layout bounds, stick parameters, language matching, physical controller order and shader dependencies passed checks.
- On M4 iPad, Japanese launcher/game menus, diagnostic Xbox YXAB previews, settings footers and button settings were checked. Diagnostic selection changes images only; it neither fakes a controller connection nor changes input mappings.
- An M4 3D character-scene HDR sample showed a raw floating-point peak of 3.625 and an output peak of 2.121, establishing that extended values reached output. This is not all-song HDR visual acceptance. Game HDR remains off by default.
- Localization keys and format placeholders were checked for consistency, with only the three complete menu languages selectable. Fixed keyboard mappings and physical controller positions remained intact.
- Rendering fixes target the original resources and behavior. Saturation or brightness adjustments are not used to stand in for material fixes.
- HDR, stage RT and folding-device adaptation were experimental. SDR was the default; frame generation was not yet attached to the game in 0.1.4.
- XYAB artwork baked into help images and controller illustrations can retain Switch labels. That does not mean actual input positions have been swapped.
- Back up saves before updating. Installing over the existing version can retain resources and progress. Public packages exclude personal saves, `prod.keys` and local development configuration.

## Build 9 research: real-game frame interpolation, October 22

This section describes local build 9 research. Build 10 includes the path, but it has not become an accepted quality preset and remains off by default.

- Final color frames from real NVN gameplay feed a 30→60 display path. Source game submissions are approximately 30 FPS; generated midpoints alternate with real frames at approximately 60 presentations/s. Both frame types produced actual presentation callbacks on Mac M3 Max.
- The candidate uses bidirectional image-block matching and motion compensation, **not MetalFX frame interpolation**. It lacks validated original motion vectors, matching depth and independent rhythm-note/UI inputs. MetalFX Spatial remains a separate upscaling function.
- The path handles source-texture snapshots, dependencies between Metal 4 and traditional queues, history resets on pause/background, scene-cut fallbacks and separate source/generated counters. The experiment is SDR-only. Build 16 adds source60/display120 research and Spatial output at supported resolutions. Selecting HDR returns to native60; the modes are mutually exclusive.
- Synthetic moving graphics produced lower midpoint error than repeated real frames; cuts use the current frame directly. Real-time 3D captures of **“愛言葉” (Ai Kotoba)** still showed hair, silhouette and background artifacts. **Real-game visual acceptance failed.**
- A stricter edge-threshold alternative degraded into repeating the current frame and was not retained as a “fix.” A 60 FPS counter does not prove acceptable images or 60 real game-state updates/s.
- Dropping source frames to 30 changes game frame-processing frequency and adds display latency. Song timing, judgment windows and controller/touch feedback need regression tests. Lower whole-device power, stable60 on all devices and reliable rhythm play are not established.
- Normal launch remains native60; a power-saving interpolation preset is not selectable. Explicit research environment `PJDV_GAME_FG=1` enables this candidate. It is not a recommended normal-play setting.

Raw frames, generated images, compile logs and experiment records remain on the external development volume under `Build/GameFG-20261021`. Next steps require reliable game motion/depth inputs and rhythm-note/UI handling, followed by visual, timing and energy comparisons.

## Build 10 content recognition and language detection

- Base packages may omit updates and DLC. Metadata selects the highest update version. DLC declarations include only content actually present and completely verified; leftover directories are not counted as installed DLC.
- If metadata is absent, content must be uniquely identifiable. Missing metadata components, conflicting same-version updates, the wrong Title ID and corrupt integrity blocks are rejected. Renamed NCAs are resolved through CNMT content SHA-256 values.
- Unlocking changes the native save's availability/ownership bits. It retains only song records registered by the original game and invents no charts, songs or scores. Costume/item visibility comes from the current resource database. One original-save backup is retained.
- Available languages require both text tables and menu image/animation resources. `str_array.bin` alone is insufficient. Host and game use the same language, with Japanese fallback. The three complete languages in the tested JP package work normally.
- Format references: [hactool NCA/PFS0 declarations](https://github.com/SciresM/hactool/blob/master/nca.h) and [Atmosphere CNMT declarations](https://github.com/Atmosphere-NX/Atmosphere/blob/master/libraries/libstratosphere/include/stratosphere/ncm/ncm_content_meta.hpp). This project independently implements the format reader; these references are not original game source code.
- `Tests/ImportVariants/build_fixtures.py` creates small synthetic XCIs. `ContentTests.swift` checks base-only imports, update priority, arbitrary DLC subsets, new indexes, complete languages, cancellation/resume, refusal to overwrite a different version and source preservation. Fixtures contain no commercial assets and do not establish complete compatibility with real resource versions.

## Build 10: Big Sur and GPU tiers, October 22

- Minimum hardware: M1/Apple GPU family 7. The Mac Catalyst target is 14.0, corresponding to macOS 11.0; the normal-exit helper also targets macOS 11.0. First-generation M1 Macs shipped with Big Sur; see [Apple's announcement](https://www.apple.com/newsroom/2020/11/macos-big-sur-is-here/). This remains a compatibility candidate, not Big Sur hardware qualification.
- Feature eligibility follows GPU family. Families 7/8 default to 720p and cap at 1080p, with HDR/RT/120 disabled. Family 9+ retains advanced options; build 16 iPhone is still capped at 1080p/60. Upgrading the OS does not upgrade the GPU tier.
- API availability is checked independently of hardware eligibility. Older systems use standard Metal encoders, MTLArgumentEncoder resource handles and classic drawable presentation. Missing GPU-address/display-link APIs are not invoked. MetalFX is weak-linked with ordinary scaling as fallback. GPU family alone cannot enable an API absent from the OS.
- Game RT no longer has an unnecessary OS-26 gate, but still requires family 9+, fragment ray-tracing capability and the actual acceleration-structure APIs. HDR tests no longer inherit an OS-26 requirement merely from MetalFX interpolation APIs in the same component. MetalFX interpolation itself still requires its corresponding OS APIs.
- Checks passed: Mac, iOS-17-target and Simulator Release builds; GPU-tier/output policies; MSL 2.3 compilation and argument-block layout checks for 808 regular game shaders. A separate M3 Max test save with forced family7/Big Sur API paths displayed the title, menus and Ai Kotoba 3D character/stage. Lower-tier menus disabled HDR/RT and hid outputs above 1080p.
- Forced paths do not emulate an M1 GPU, Big Sur drivers or their performance. Actual old-system startup, presentation timestamps, performance and advanced Mac HDR/RT remain unqualified. Xcode 27 recommends macOS 12+; deployment-range diagnostics remain warnings. The built Catalyst binary reports minimum14.0, Info.plist reports macOS11.0, and the helper reports11.0. The SDK was not modified and deployment versions were not merely rewritten after packaging.

## Resource-version testing

The same local combined XCI can provide real base v1.0.0 and update v1.0.9 resources for comparison without downloading another full package. Base v1.0.0 imports without DLC, Japanese/Simplified/Traditional Chinese detection, and initial difficulty/costume ownership unlocking passed. **101 selectable songs and 103 native registered records** are tracked separately; hidden/registered records are not represented as playable tracks.

Base v1.0.0 reaches gameplay/results, but Ai Kotoba's 3D PV remains black and some newer help images are absent. BNSH differences were identified: of 808 shader variants, 314 have matching control keys, 264 share code but have different control keys, and 230 have different code. Base-version translation experiments remain separate locally and have not been merged into the current renderer library. Image filters need further adaptation/validation. The running program remains adapted JP v1.0.9; arbitrary original versions/regions cannot be described as working.

## Build 14: completed import-memory validation

**October 24:** retains root auto import, folder fallback and phase/progress/I/O displays. Fixes accumulation of temporary objects during long imports and adds memory/local diagnostics. **After uninstall/reinstall on M4 iPad/iPadOS 27.2, the complete 42.72 GB XCI was reimported: 41,943,373,493 resource bytes, 27 DLC, about96 seconds, sampled import-process peak about125 MB, with no memory warning or process exit.** A complete host-side read-only resource walk and an 8 GiB streaming-memory regression also passed.

**The reported M1/8 GB/iPadOS18 device still needs direct retesting; this is not confirmation that its failure has been resolved.** See [BUILDING.md](BUILDING.md). Original program segments, generated rendering caches and game resources must be prepared locally and are excluded from published source.

## Build 16: ProMotion and clarity validation, October 24

- `PJDV_GAME_FG=1` selects source30/display60; `=2` selects source60/display120. Both require an explicit research launch and are not default performance presets. In build16, 120 additionally requires family9+, a non-iPhone device, a display maximum of at least120 Hz and Low Power Mode off. ProMotion adjusts dynamically; use actual presentation rates.
- Bidirectional block optical flow uses only final color images. It has no validated original motion/depth and does not separate notes/game UI. Generated frames do not add input processing or game-logic updates. Display latency increases; judgment timing is unqualified. Native60 is currently recommended.
- Initial 45-second M4 real-time 3D PV sampling in 39みゅーじっく！: median source59.998 and generated59.995 FPS, zero GPU errors, median interpolation-command GPU time4.62ms and sampled maximum7.06ms. Scene cuts retain real-frame fallback. These samples predate restored Spatial and are not 1440p/MetalFX/M1 or all-song performance results.
- Frame readback exposed localized stage-screen distortion. Pixel-match confidence was tightened; a120 counter was not treated as visual acceptance. On/off behavior and real/generated output after restoring Spatial were tested separately.
- Advanced resolutions follow device eligibility and no longer disappear under interpolation. Both real and generated frames can subsequently pass through Spatial. Ordinary scaling and MetalFX remain independently selectable. HDR still requires actual EDR display/API support and automatically disables game interpolation.
- Every virtual face button, D-pad direction, shoulder button, +/− and stick is adjustable. M4 checks covered A at85%, empty-space placement and Cancel retaining saved settings. Real finger dragging and actual M1 multi-touch judgment still need corresponding hardware tests.

**After Spatial was restored:** 45 one-second M4 samples of the 1080p 39music 3D PV had median sourceFPS59.998, generatedFPS59.509 and actual presentedFPS119.999. Spatial state was1 throughout; GPU errors were0. The minimum presentation sample was106.89 FPS. A separate30-second 1440p sample read back2560×1440 Spatial output, with median presentedFPS119.999, minimum96.807 and median interpolation-command GPU time7.67ms. Captures and scene cuts are included; these results do not establish an all-song120 lock. Native60/interpolation switching, pause/resume and1440p selection passed on M4. **The user confirmed restored clarity on the M4 device.**

## MOD research and future integration, October 24

The published build **does not yet import MOD packages or run MikuMikuSwitchPlugin**. Research uses upstream commit `b8025c7a540e60cd85659103983c92ba2795bc1f`:

- Its [ModLoader](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/b8025c7a540e60cd85659103983c92ba2795bc1f/source/program/ModLoader.cpp) prepends configured-priority MOD paths to the game's search list, reads `enabled`/`include` from `config.toml`, and recognizes `rom`/`rom_steam` layouts. A corresponding host resource-overlay design could leave base `GameResources` and the source XCI unchanged.
- [DatabaseLoader](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/b8025c7a540e60cd85659103983c92ba2795bc1f/source/program/DatabaseLoader.cpp) and [PvLoader](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/b8025c7a540e60cd85659103983c92ba2795bc1f/source/program/PvLoader.cpp) show that adding songs also needs database prefixes, song IDs, loop boundaries and video handling. A staged approach would first validate replacements for existing costumes/textures, then evaluate new songs with isolated test saves.
- Switch `subsdk9` and PC DLL plugins cannot be loaded as drop-in iOS/Mac plugins. Their ABI, injection framework and program offsets differ. This project requires independently adapted, fingerprinted, offline-rewritten and signed code.
- The upstream [LICENSE](https://github.com/lsmsmx/MikuMikuSwitchPlugin/blob/b8025c7a540e60cd85659103983c92ba2795bc1f/LICENSE) contains GPLv2 text. Specific files/dependencies and redistribution requirements must be checked before implementation reuse. This round researched source; it did not merge upstream plugin code.

## build17: AutoPlay, diagnostics and hot switching, October 24

The following describes the build17 lightweight preview and its actual validation scope. Interpolated image quality, rhythm timing and lower-end performance remain unqualified.

- AutoPlay is enabled on the launcher only and defaults to off. A visible test/no-records indicator stays in game. Every session uses a fresh disposable save copy and never merges automatic scores into the normal profile. The optional hook requires the verified Japanese 1.0.9 executable fingerprint; offsets are not applied to arbitrary imported versions.
- Real-Mac tests completed Ai Kotoba EXTREME with402 COOL and Ghost Rule EXTREME with715 COOL, all other judgments0. Normal save SHA-256 hashes were unchanged after complete runs. AutoPlay verifies workload behavior; it does not qualify manual input, audio synchronization or judgment timing.
- The Ghost Rule windowed run produced394 half-second samples: median actual presentedFPS53.39; presentation-interval p50/p95/p9916.67/25.00/33.33ms; peak app footprint approximately2377MiB. Hardware was M3 Max,16CPU/40GPU/64GiB;1080p Spatial, native60 target,SDR. Concurrent device control and window switching were present. These measurements **do not demonstrate a stable60 lock or power savings**.
- The menu groups30/60/120, distinguishing native60 from30→60 and native120 from60→120. Native120 is restricted to the requested Mac allowlist (M3 Ultra/M5 Max/M5 Ultra) plus an actual120Hz display. The120-interpolation experiment allows family9+, actual120Hz and non-Low-Power operation. Eligibility is not a performance guarantee. Native30/120 change guest cadence and still need timing-specific validation.
- Game interpolation uses an image-flow research backend, **not the MetalFX frame-interpolation API**. It currently includes chart/UI in the full color image and adds display latency. MetalFX Spatial is a separate upscaling step. Game interpolation and HDR are mutually exclusive.
- The output menu independently hides upper-left diagnostics and the FPS/CPU/RAM window, retaining preferences across restarts; the AutoPlay test indicator remains visible. Hiding and persistence passed on Mac. Diagnostics read SoC, CPU cores and total physical RAM; Mac GPU cores use the device report. Where iPad has no public core-count interface, an exact known-model specification is labelled or the count is explicitly unknown. Observed values: M3 Max16/40/64.0GiB; M4 iPad10/10(spec)/15.1GiB. The latter is the OS-reported physical-memory value.
- All18 virtual controls remain individually resizable and movable before launching the game. Mac/M4 checks covered the launcher entry, A-button scaling and Cancel retaining settings. Real-finger multi-touch dragging still needs interaction regression.

**Hot-switch status:** In Ai Kotoba EXTREME on Mac,1080p Spatial→1440p Spatial→720p continued rendering and chart play. The earlier M4 candidate froze when enabling60→120. Diagnostics showed successful GPU command completion without actual presentation; disabling Spatial or switching to SDR first did not prevent it. The later candidate stops MTKView's placeholder draw loop once the guest owns CAMetalLayer and updates HUD through the session timer; input remains event-driven. The M4 retest did not reproduce that stall.

M4 scenes were the real-time3D **39music PV mode** and retry menu:1080p→1440p Spatial→60→120→720p→1080p Spatial→30→60→native60 continued displaying and replaying. Checkpoints reported actual presentation around120.00 FPS (real59.51+generated60.50),60.00 FPS (real29.51+generated29.51), and60.00 after returning to native; cumulative GPU errors0. Native30/60 also switched between actual30/60 in title/attract scenes. Checkpoints are not an all-song FPS guarantee. M4 high-difficulty rhythm play and manual judgment timing were not qualified this round. Mac windowed presentation remained below target, so resolving the stall is not a completed performance optimization. The current M3 Max is outside the native120 allowlist; native120 was not tested. Interpolation artifacts, added display latency, HDR exclusivity and cross-device regression remain experimental limitations.


## build18: MOD Manager, loading disabled, October 25

The launcher now offers MOD Manager (Experimental): manually select ZIP/ZIP64 or an extracted folder, inspect resource/plugin/code layouts and save the original source bookmark plus findings. Extract 7z/RAR first. Registrations can be reinspected or removed without deleting sources. Nothing is copied, extracted or loaded, and XCI/assets/saves are unchanged. ZIP directory inspection does not validate payload CRC, TOML semantics or game compatibility.

Research targets MikuMikuSwitchPlugin `13bc9fa`; the reserved read-only capability/ABI still refuses activation. See the [entry/test guide](Reports/MOD-ENTRY-build18.md), [Switch installation research](Reports/SWITCH-MOD-IMPORT-20261025.md) and [interface report](Reports/MOD-INTERFACE-build18.md). build18 provides lightweight IPA/DMG installers and matching source. Actual Mac ZIP/folder registration, saved-bookmark reinspection, cancellation and registration removal passed. iOS, Simulator and Mac builds passed; the iPad device entry remains untested. No real MOD in-game compatibility is claimed.


## Build 19: MOD downloads/imports and FPS hot switching, October 29

Launcher → MOD Manager (Experimental) → Browse/download MODs opens GameBanana's Mega Mix+ catalog. Downloaded ZIPs are extracted on disk and CRC-validated, with retry, current file, progress and speed. Extract 7z/RAR externally before importing the folder. A single utility worker uses 64 KiB chunks, cancellation and free-space checks; download/expanded limits are 16/32 GiB.

**Imports remain inactive. This release does not automatically convert or enable PC MODs.** Only selected model/song samples were converted offline and tested in isolated simulator sessions. See the [MOD report](Reports/MOD-DOWNLOAD-CONVERSION-20261029.md) for Umiyuri covers/Chinese lyrics and Electric Angel's full completion. Some Calc shots remain inverted; X Charts still needs New Classics mechanics. Private test overlays are not included in installers.

The Mac CAMetalDisplayLink supported path no longer falls through to a legacy presentation reset. Earlier M3 Max main-menu/Ghost Rule PV regression covered native30/60,30→60,60→120 round trips with continuing animation/input and zero GPU errors. These functional checks do not qualify full-song performance or rhythm timing. No new iPad device acceptance was performed.

Unsigned IPA: re-sign with your own valid identity. The arm64 Mac DMG is ad-hoc signed and not notarized. No XCI, GameResources, production keys, personal saves or local signing profiles are included. Successful download/extraction is not runtime compatibility.
