// CommunityFeedWindow — "Show other peoples thumbs" floating viewer.
//
// Fetches the latest 50 community thumbnails (server caps each
// machine_uuid at 3 entries so one prolific contributor can't
// dominate) and renders them as a 3-column grid of cards. Each
// card stacks the thumbnail on top, then target chip + metadata
// rows underneath. Entries from THIS machine get a "you" badge
// so the user can spot their own contributions.
//
// Sizing: the JPEG stored on Supabase IS the downscaled version
// (≤800 px on the long edge — done client-side by
// CommunityShare.makeThumbnailJPEG before upload). The grid shows
// it at 140×112 pt for browsing; double-click opens a sheet with
// the image rendered at its actual stored pixel size, which is
// what "1:1" means in this context (no higher-resolution copy
// exists on the server by privacy design).
//
// Refresh button at the top re-fetches. Loading + empty + error
// states all handled inline. Non-modal floating Window — the user
// can keep it open while continuing to work in the main window.
import SwiftUI

struct CommunityFeedWindow: View {
    @State private var entries: [CommunityFeedEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var lastRefreshed: Date?
    /// When non-nil, the focused-thumbnail sheet is presented at the
    /// stored 1:1 pixel size. Cleared on close.
    @State private var focusedEntry: CommunityFeedEntry?

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { loadIfNeeded() }
        .sheet(item: $focusedEntry) { entry in
            FocusedThumbnailView(entry: entry) {
                focusedEntry = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.brandGradient)
            VStack(alignment: .leading, spacing: 0) {
                Text("Community Stacks")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Text(subtitleText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var subtitleText: String {
        if isLoading { return "Loading…" }
        if let err = loadError { return "Error: \(err)" }
        let countNote = "\(entries.count) recent stack\(entries.count == 1 ? "" : "s")"
        if let ts = lastRefreshed {
            let f = DateFormatter()
            f.timeStyle = .short
            return "\(countNote) · refreshed at \(f.string(from: ts)) · double-click any thumbnail to view 1:1"
        }
        return countNote
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let err = loadError, entries.isEmpty {
            errorState(err)
        } else if !isLoading && entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(entries) { entry in
                        FeedCard(entry: entry) {
                            focusedEntry = entry
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No community stacks yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Be the first — run a stack, then click Yes when prompted to upload your thumbnail.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text("Could not load community feed")
                .font(.system(size: 13, weight: .semibold))
            Text(msg)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Try again") {
                Task { await refresh() }
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Networking

    private func loadIfNeeded() {
        guard entries.isEmpty, !isLoading else { return }
        Task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let fetched = try await CommunityShare.fetchFeed(limit: 50)
            entries = fetched.sorted { $0.createdAtDate > $1.createdAtDate }
            lastRefreshed = Date()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - One feed card (vertical layout for grid)

private struct FeedCard: View {
    let entry: CommunityFeedEntry
    let onDoubleClick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .onTapGesture(count: 2, perform: onDoubleClick)
            targetRow
            datetimeRow
            statsRow
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(entry.isMine
                      ? AppPalette.accent.opacity(0.06)
                      : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(entry.isMine
                        ? AppPalette.accent.opacity(0.5)
                        : Color.secondary.opacity(0.18),
                        lineWidth: entry.isMine ? 1.2 : 0.5)
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = URL(string: entry.signedUrl), !entry.signedUrl.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholderImage(systemName: "photo.badge.exclamationmark")
                case .empty:
                    placeholderImage(systemName: "photo")
                @unknown default:
                    placeholderImage(systemName: "photo")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .help("Double-click to view at 1:1 (\(entry.signedUrl.isEmpty ? "no URL" : "stored size"))")
        } else {
            placeholderImage(systemName: "photo")
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func placeholderImage(systemName: String) -> some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: systemName)
                .font(.system(size: 24))
                .foregroundColor(.secondary)
        }
    }

    private var targetRow: some View {
        HStack(spacing: 6) {
            if let target = entry.target, !target.isEmpty {
                Text(target)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [
                                Color(red: 0.55, green: 0.34, blue: 0.92),
                                Color(red: 0.40, green: 0.20, blue: 0.78),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        ))
                    )
            } else {
                Text("unknown")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            if entry.isMine {
                Text("YOU")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppPalette.accent))
            }
            Spacer()
        }
    }

    private var datetimeRow: some View {
        // UTC dates + times so contributors across timezones can be
        // compared meaningfully. Suffix "Z" on the time disambiguates
        // it from local time at a glance (ISO 8601 convention).
        HStack(spacing: 8) {
            metadataChip(systemName: "calendar", value: dateStringUTC)
            metadataChip(systemName: "clock", value: timeStringUTC + "Z")
            // Always render the duration chip so the user can see at
            // a glance whether the contributor's row carries timing
            // info. "—" means the row was uploaded before the
            // elapsed_sec column existed (rows older than 2026-05-03).
            metadataChip(systemName: "stopwatch", value: durationString)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 8) {
            if let n = entry.frameCount, n > 0 {
                metadataChip(systemName: "square.stack.3d.down.right",
                             value: "\(n.formatted())f")
            }
            metadataChip(systemName: "person.crop.circle", value: machineShort)
        }
    }

    private func metadataChip(systemName: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemName)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    /// Reusable UTC formatter — DateFormatter creation is expensive,
    /// caching at the type level keeps each card render cheap.
    private static let utcDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd"
        return f
    }()

    private static let utcTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private var dateStringUTC: String {
        Self.utcDateFormatter.string(from: entry.createdAtDate)
    }

    private var timeStringUTC: String {
        Self.utcTimeFormatter.string(from: entry.createdAtDate)
    }

    /// Always returns a string. "—" when no elapsed_sec — those rows
    /// came in before the column existed (pre-2026-05-03).
    private var durationString: String {
        guard let s = entry.elapsedSec, s > 0 else { return "—" }
        if s < 60 { return String(format: "%.1fs", s) }
        let mins = Int(s) / 60
        let secs = Int(s) % 60
        return "\(mins)m\(String(format: "%02d", secs))s"
    }

    private var machineShort: String {
        String(entry.machineUuid.prefix(8))
    }
}

// MARK: - Focused thumbnail sheet (1:1)

/// Modal sheet that displays the thumbnail at its native stored
/// pixel size — that's "1:1" for the community feed because there
/// is no full-resolution version on the server (the upload pipeline
/// downscales to ≤800 px before sending). If the image is larger
/// than the available sheet area, it scrolls.
private struct FocusedThumbnailView: View {
    let entry: CommunityFeedEntry
    let onClose: () -> Void

    @State private var loaded: NSImage?
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(0)
        }
        .frame(minWidth: 600, minHeight: 500)
        .frame(idealWidth: 900, idealHeight: 720)
        .background(Color(NSColor.windowBackgroundColor))
        .task { await loadFullSize() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let target = entry.target {
                Text(target)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [
                                Color(red: 0.55, green: 0.34, blue: 0.92),
                                Color(red: 0.40, green: 0.20, blue: 0.78),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        ))
                    )
            }

            // Stack-time pill — more prominent than the rest of the
            // metadata so users can compare hardware at a glance.
            // ("Wow that 30 s render is on an Intel Mac, my M2 finishes
            // in 5 s.")
            if let dur = durationDisplay {
                HStack(spacing: 4) {
                    Image(systemName: "stopwatch.fill")
                        .font(.system(size: 11))
                    Text(dur)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppPalette.accent))
                .help("Wall-clock time the stack took on the contributor's machine.")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(metadataSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                if let dimText = dimensionsText {
                    Text(dimText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Close") { onClose() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Formatted "12.3s" or "2m15s" string used in the pill.
    private var durationDisplay: String? {
        guard let s = entry.elapsedSec, s > 0 else { return nil }
        if s < 60 { return String(format: "%.1fs", s) }
        let mins = Int(s) / 60
        let secs = Int(s) % 60
        return "\(mins)m\(String(format: "%02d", secs))s"
    }

    @ViewBuilder
    private var content: some View {
        if let nsImg = loaded {
            // Mac-native NSScrollView wrapper — pinch-to-zoom,
            // smart-magnify (two-finger double-tap), and scroll-bar
            // panning all work for free. Min 0.25× / max 8× — beyond
            // 8× the 800-px JPEG turns into mush so capping it is
            // honest about what's there.
            ZoomableImageView(image: nsImg)
        } else if loadFailed {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)
                Text("Could not load full-size image")
                    .font(.system(size: 12, weight: .semibold))
                Text("The signed URL may have expired (TTL is 1 h). Refresh the feed and try again.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var metadataSummary: String {
        let ts = entry.createdAtDate
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        var parts = [f.string(from: ts)]
        if let n = entry.frameCount, n > 0 { parts.append("\(n.formatted()) frames") }
        if let s = entry.elapsedSec, s > 0 {
            let mins = Int(s) / 60
            let secs = Int(s) % 60
            parts.append(s < 60 ? String(format: "%.1fs", s) : "\(mins)m\(String(format: "%02d", secs))s")
        }
        parts.append("uuid \(entry.machineUuid.prefix(8))")
        if entry.isMine { parts.append("YOU") }
        return parts.joined(separator: " · ")
    }

    private var dimensionsText: String? {
        guard let img = loaded else { return nil }
        let w = Int(img.size.width)
        let h = Int(img.size.height)
        return "\(w) × \(h) px (1:1, the stored thumbnail size)"
    }

    private func loadFullSize() async {
        guard let url = URL(string: entry.signedUrl), !entry.signedUrl.isEmpty else {
            loadFailed = true
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = NSImage(data: data) {
                loaded = img
            } else {
                loadFailed = true
            }
        } catch {
            loadFailed = true
        }
    }
}

// MARK: - Pinch-zoomable image (NSScrollView wrapper)

/// `NSClipView` subclass that keeps the document view centered when
/// it's smaller than the visible bounds. The canonical
/// "centered-image-in-scrollview" pattern — survives magnification
/// changes, window resizes, and image swaps without any per-event
/// scrolling gymnastics.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView else { return rect }
        if rect.width > docView.frame.width {
            rect.origin.x = (docView.frame.width - rect.width) / 2
        }
        if rect.height > docView.frame.height {
            rect.origin.y = (docView.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Mac-native zoomable image — wraps an `NSImageView` in an
/// `NSScrollView` with `allowsMagnification = true` and a
/// centering clip view. Pinch (trackpad magnify), smart-magnify
/// (two-finger double-tap), and scroll-bar / two-finger panning
/// all work for free; no SwiftUI gesture plumbing needed.
///
/// Initial magnification is `1.5×` per user request (2026-05-03) —
/// 1.5× of the stored 800-px-long-edge JPEG fills more of the
/// window so users can immediately see detail. They can pinch out
/// to shrink (down to 0.25× = fit) or pinch in to 8×.
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    private static let initialMagnification: CGFloat = 1.5

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 8.0
        scroll.magnification = Self.initialMagnification
        scroll.backgroundColor = .controlBackgroundColor

        // Replace the default clip view with our centering subclass.
        // Order matters: install the clip view FIRST, then the
        // document view (so the clip view's centering math has
        // something to constrain against).
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.setFrameSize(image.size)

        scroll.documentView = imageView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // If the image identity changes, swap the document view's
        // image + reset zoom to the 1.5× starting magnification.
        // The centering clip view re-centers automatically on the
        // next layout pass.
        guard let imageView = scroll.documentView as? NSImageView else { return }
        if imageView.image !== image {
            imageView.image = image
            imageView.setFrameSize(image.size)
            scroll.magnification = Self.initialMagnification
        }
    }
}
