# File Formats

## Read

| Format | Bit depth | Channels | Notes |
| --- | --- | --- | --- |
| TIFF | 8, 16, Float16 | mono / RGB / RGBA | Float TIFFs are normalised through an 8-bit RGB context for thumbnails. |
| PNG | 8, 16 | RGB / RGBA | |
| JPEG | 8 | RGB | |
| SER | 8, 16 | mono / Bayer | RGGB / GRBG / GBRG / BGGR — demosaiced on the GPU. |
| AVI | varies | varies | Catalog-recognised; full lucky-stack demux pending. |

## Write

| Format | Bit depth | Channels | Default for |
| --- | --- | --- | --- |
| TIFF | 16-bit float | RGBA | Stabilization, lucky-stack, sharpen, tone-curve outputs |
| PNG | 8 | RGB | Optional |
| JPEG | 8 | RGB | Optional |

All in-engine textures are `rgba16Float`. Lucy-Richardson and Wiener iteration would lose precision in 8-bit; tone-curve LUTs become coarse.

## SER reader specifics

- Memory-mapped (`mmap`) for instant frame access — opening a 10 GB SER is constant-time.
- Header parsed up-front (frame count, dimensions, Bayer pattern, UTC timestamp if present).
- Bayer demosaic uses bilinear interpolation in a Metal kernel.
- Mono frames are unpacked directly into the red channel of an RGBA texture.
- Endianness is little-endian (per SER spec).

## AVI status

AVI files appear in the file list and can be selected, but Lucky Stack will currently surface a friendly error: "AVI lucky-stack support is coming — please convert to SER for now." The next iteration plugs `AVAssetReader` into the Lucky Stack engine.

If you want immediate AVI support, convert with `ffmpeg`:

```bash
ffmpeg -i input.avi -c:v rawvideo -pix_fmt gray16le output.ser  # not actually SER, but uncompressed
```

(SER conversion needs a SER-specific tool like ImPPG's converter; ffmpeg can extract per-frame TIFFs which AstroSharper's file-batch can process.)
