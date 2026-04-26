# Output Folders

AstroSharper runs in a sandbox, which means it can only write to:

1. The container's `Documents/AstroSharper Outputs/` (always allowed)
2. Folders the user explicitly grants access to (security-scoped bookmarks)

This page explains the fallback chain so you always know where your files end up.

## Fallback order

```
   1. Picked output folder      (Settings → Output Folder section)
        └─ persisted as a security-scoped bookmark in UserDefaults
   2. Auto folder next to input
        └─ <input-folder>/_AstroSharper/
   3. Sandbox container
        └─ ~/Library/Containers/<bundle-id>/Data/Documents/AstroSharper Outputs/
```

AstroSharper attempts each level top-down with a quick probe-write (creates a temp file, then deletes it). The first level that succeeds is used silently.

The status bar always shows the path that ended up being used.

## Picking a folder

Settings panel → **Output Folder** section → "Choose…" button. A standard Open Panel asks for folder selection. AstroSharper:

1. Stores a security-scoped bookmark
2. Probe-writes to verify it's actually writable (NAS shares sometimes mount but reject writes)
3. If the probe fails, surfaces a friendly error and falls back

The bookmark survives across launches — restart AstroSharper and your folder is reconnected automatically.

## NAS / network drives

Sandboxed apps can write to mounted NAS shares as long as the user picks the folder via the Open Panel (which extends sandbox access). Tested:

- ✅ SMB mounts (macOS Finder)
- ✅ AFP mounts
- ⚠️ NFS mounts may fail probe-write — fallback handles it gracefully
- ⚠️ Disconnected drives — auto-fallback kicks in, status bar warns

## Lucky Stack subfolder layout

```
   <output>/
   └── _luckystack/
       ├── <name>_lucky.tif       (default slider-based run)
       ├── f200/<name>_lucky.tif  (top-200 absolute count)
       ├── f500/<name>_lucky.tif
       ├── p15/<name>_lucky.tif   (top-15 % run)
       └── p35/<name>_lucky.tif
```

## Stabilize / sharpen / tone subfolder layout

The Memory tab's Save All groups files by accumulated op trail:

```
   <output>/
   ├── stabilized/              (only stabilize ops)
   │   └── <name>_aligned.tif
   ├── stabilized_sharp/        (stabilize + sharpen)
   │   └── <name>_aligned_sharp.tif
   ├── stabilized_sharp_tone/
   │   └── <name>_aligned_sharp_tone.tif
   └── processed/               (mixed op trails)
       └── <name>_*.tif
```

When every memory frame has the same op trail, AstroSharper writes them into one named folder. Mixed trails go into the generic `processed/`.

## File-batch (⌘R) layout

```
   <output>/
   └── _processed/
       └── <name>_<ops>.tif
```

`<ops>` reflects which sections were enabled: `_sharp`, `_aligned`, `_tone`, or combinations.

## Common gotchas

- **"You don't have permission" alerts** — almost always a sandbox issue. Use the picker rather than typing a path.
- **Files going to the sandbox container** — happens when the picked folder isn't writable. Look at the status bar to confirm where they actually landed.
- **Removed external drive** — files fall back to the sandbox container. They're not lost, just elsewhere.
