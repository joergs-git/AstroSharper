// Presents a list of still images as a frame sequence.
//
// Smart telescopes — Vaonis Vespera, ZWO Seestar, DwarfLab — never write
// video. Every capture arrives as a folder of individual subs, so the
// entire lucky-imaging pipeline was unreachable for their owners without
// first converting the folder to SER or AVI in a separate tool (PIPP is
// Windows-only; the ffmpeg route needs a codec most recipes get wrong).
//
// Rather than writing an intermediate container, this reader implements
// `SourceReader` directly over the file list. Nothing is transcoded and
// nothing lands on disk: the stack runner asks for frame N and gets a
// decoded texture, exactly as it would from a SER. That avoids the cost
// of the detour — a second full copy of the data, the conversion wait,
// and a quantisation step that would have to throw away float FITS
// precision before stacking it.
//
// SCOPE: this is lucky imaging over a sequence of the same subject —
// Moon, Sun, planets. It is not a deep-sky integration path; those need
// calibration frames, plate-solved registration and rejection stacking,
// which is a different program (Siril, APP, PixInsight).
import Foundation
import Metal

enum ImageSequenceError: Error, LocalizedError {
    case empty
    case tooFewFrames(count: Int)
    case unreadable(URL)
    case dimensionMismatch(url: URL, expected: (w: Int, h: Int), got: (w: Int, h: Int))

    var errorDescription: String? {
        switch self {
        case .empty:
            return "No readable images in the sequence."
        case .tooFewFrames(let n):
            return "A sequence needs at least 2 frames to stack (got \(n))."
        case .unreadable(let url):
            return "Could not read image dimensions from \(url.lastPathComponent)."
        case .dimensionMismatch(let url, let expected, let got):
            return "\(url.lastPathComponent) is \(got.w)×\(got.h) but the sequence is \(expected.w)×\(expected.h). Every frame must have the same dimensions."
        }
    }
}

final class ImageSequenceReader: SourceReader {
    /// The folder holding the frames. `SourceReader.url` is used for
    /// diagnostics, cache keys and output naming, and the folder is the
    /// thing that identifies this sequence — an individual frame would
    /// name the output after an arbitrary member of the set.
    let url: URL

    /// Frame files in presentation order.
    private let frameURLs: [URL]

    let imageWidth: Int
    let imageHeight: Int

    init(frameURLs: [URL]) throws {
        guard let first = frameURLs.first else { throw ImageSequenceError.empty }
        guard frameURLs.count >= 2 else {
            throw ImageSequenceError.tooFewFrames(count: frameURLs.count)
        }
        self.frameURLs = frameURLs
        self.url = first.deletingLastPathComponent()

        // Validate geometry up-front from headers only — no pixel decode.
        // A mismatch discovered halfway through a 1000-frame stack would
        // waste minutes and produce a corrupt result; this costs
        // milliseconds and fails with the offending filename.
        guard let firstDims = FileCatalog.readDimensions(url: first) else {
            throw ImageSequenceError.unreadable(first)
        }
        self.imageWidth = firstDims.width
        self.imageHeight = firstDims.height
        for candidate in frameURLs.dropFirst() {
            guard let dims = FileCatalog.readDimensions(url: candidate) else {
                throw ImageSequenceError.unreadable(candidate)
            }
            guard dims.width == firstDims.width, dims.height == firstDims.height else {
                throw ImageSequenceError.dimensionMismatch(
                    url: candidate,
                    expected: (firstDims.width, firstDims.height),
                    got: (dims.width, dims.height)
                )
            }
        }
    }

    /// Build from a folder, taking every supported still image in it.
    /// Frames are ordered by `localizedStandardCompare`, which sorts
    /// `frame_2` before `frame_10` — a plain lexical sort would
    /// interleave them and scramble the time axis.
    convenience init(folder: URL) throws {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        let frames = contents
            .filter { ImageSequenceReader.isStillImage($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        try self.init(frameURLs: frames)
    }

    /// Still-image extensions that can act as sequence frames. Video
    /// containers are excluded — they are sequences in their own right
    /// and have their own readers.
    static func isStillImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return FileCatalog.supportedExtensions.contains(ext)
            && !FileCatalog.videoExtensions.contains(ext)
            && ext != FileCatalog.serExtension
    }

    // MARK: - SourceReader

    var frameCount: Int { frameURLs.count }

    /// Bits per channel of the first frame, used for reporting only. The
    /// decode path normalises everything to `rgba16Float` regardless.
    var pixelDepth: Int {
        FileCatalog.fitsExtensions.contains(frameURLs[0].pathExtension.lowercased())
            ? ((try? FitsFrameReader(url: frameURLs[0]))?.pixelDepth ?? 16)
            : 16
    }

    /// Frames reach the pipeline already demosaiced: still images are RGB
    /// by construction, and a CFA FITS is debayered inside
    /// `FitsFrameReader.loadFrame`. Matches how `AviReader` reports.
    var colorID: SerColorID { .rgb }

    /// Still images carry no frame rate. Playback falls back to its
    /// default rate; nothing in stacking depends on this.
    var nominalFrameRate: Double? { nil }

    /// Filesystem creation date of the first frame. FITS `DATE-OBS`
    /// would be more precise but parsing a full frame purely for a
    /// timestamp is not worth it at open time; nothing in the stacking
    /// path uses this today.
    var captureDate: Date? {
        (try? frameURLs[0].resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    func loadFrame(at index: Int, device: MTLDevice) throws -> MTLTexture {
        let clamped = max(0, min(frameURLs.count - 1, index))
        let frameURL = frameURLs[clamped]
        if FileCatalog.fitsExtensions.contains(frameURL.pathExtension.lowercased()) {
            // FitsFrameReader owns FITS decode, including the CFA
            // demosaic — reusing it keeps one implementation of both.
            return try FitsFrameReader(url: frameURL).loadFrame(at: 0, device: device)
        }
        return try ImageTexture.load(url: frameURL, device: device)
    }
}
