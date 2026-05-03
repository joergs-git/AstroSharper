// Lucky-Stack panel section. Operates on whatever SER files are marked /
// selected in the main file list — no separate file picker, single source of
// truth. Output goes to the same `customOutputFolder` (or `<root>/_processed`
// fallback) used by the normal sharpen pipeline.
import AppKit   // NSOpenPanel for the calibration master-frame pickers
import SwiftUI
import UniformTypeIdentifiers   // UTType.tiff / .png / .jpeg for picker filtering

struct LuckyStackSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var expanded = false   // start collapsed for a clean panel

    private var serTargets: [FileEntry] {
        let ids = app.batchTargetIDs
        return app.catalog.files.filter { ids.contains($0.id) && $0.isSER }
    }
    private var serCount: Int { serTargets.count }
    private var allSerInCatalog: Int { app.catalog.files.filter { $0.isSER }.count }
    /// Lucky Stack is meaningless without SER input. We disable both the
    /// header chevron and the run button so the section can't accidentally
    /// be expanded on an empty / TIFF-only folder.
    private var disabled: Bool { allSerInCatalog == 0 }

    /// One-line summary of which sharpening / tone passes will fire
    /// on the next stacked output, given the current toggle state.
    /// Surfaced under the toggles so the user can verify before
    /// running — catches the "I deselected everything but it still
    /// looks sharpened" failure mode by listing each path that
    /// modifies the saved TIFF beyond the bare accumulator.
    private var savedFilePipelineSummary: some View {
        var firing: [String] = []
        // 1. Multi-AP local refinement (changes alignment, not
        //    sharpening per se, but affects detail).
        if (app.luckyStack.autoNuke || app.luckyStack.multiAP.enabled)
            && app.luckyStack.mode == .scientific {
            firing.append("multi-AP")
        }
        // 2. Auto-PSF Wiener deconvolution — THE sharpening path.
        if app.luckyStack.autoNuke || app.luckyStack.autoPSF {
            firing.append("auto-PSF Wiener")
        }
        // 3. Tiled deconv (mask-based blend on top of Wiener).
        if app.luckyStack.tiledDeconv && (app.luckyStack.autoNuke || app.luckyStack.autoPSF) {
            firing.append("tiled deconv")
        }
        // 4. Pre / post denoise around the Wiener pass.
        if app.luckyStack.denoisePrePercent > 0 || app.luckyStack.denoisePostPercent > 0 {
            firing.append("denoise")
        }
        // 5. Bake-in: applies the live Sharpen + Tone settings to the
        //    saved file. The user-controlled "I want my preview baked
        //    into the TIFF" path. This is the most likely silent
        //    sharpening culprit.
        if app.luckyStack.bakeInProcessing {
            firing.append("bake-in (Sharpen + Tone)")
        }
        // 6. Auto-tone (subject-aware gamma).
        if app.luckyStack.autoRecoverDynamicRange {
            firing.append("auto-tone")
        }

        let summary: String = firing.isEmpty
            ? "Saved file: bare accumulator (no sharpening, no tone adjust)."
            : "Saved file will apply: " + firing.joined(separator: " → ") + "."

        return HStack(spacing: 4) {
            Image(systemName: firing.isEmpty ? "circle" : "wand.and.stars")
                .font(.system(size: 9))
                .foregroundColor(firing.isEmpty ? .secondary : .accentColor)
            Text(summary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// Background gradient for the AutoNuke pill. Bright when ON
    /// (engine taking over), muted when OFF (manual control mode).
    private var autoNukeBackground: LinearGradient {
        if app.luckyStack.autoNuke {
            return LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.34, blue: 0.22),  // hot orange
                    Color(red: 0.82, green: 0.18, blue: 0.62),  // magenta
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.22, green: 0.51, blue: 0.95),  // blue
                Color(red: 0.55, green: 0.34, blue: 0.92),  // violet
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Click anywhere on chevron, icon, or "Lucky Stack" text
                // toggles collapse — wrapping the whole row in a single
                // Button so the user doesn't have to aim for the small
                // chevron. Matches SectionContainer styling (12pt bold
                // chevron, bold title) so all panel sections look /
                // behave the same.
                Button {
                    if !disabled {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        Image(systemName: "sparkles.tv.fill")
                            .foregroundColor(disabled ? .secondary : .accentColor)
                        Text("Lucky Stack")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(disabled ? .secondary : .primary)
                        if disabled {
                            Text("· no .ser files")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)

                Spacer()
                Text(targetCountLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .opacity(disabled ? 0.55 : 1.0)
            .help(disabled ? "Lucky Stack runs on .ser video files. Open a folder containing SharpCap / FireCapture .ser captures to enable." : "")

            if expanded && !disabled {
                Picker("Mode", selection: $app.luckyStack.mode) {
                    ForEach(LuckyStackMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(app.luckyStack.mode.description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Keep best").font(.caption)
                        Spacer()
                        Text("\(app.luckyStack.keepPercent) %")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(app.luckyStack.keepPercent) },
                            set: { app.luckyStack.keepPercent = max(1, min(100, Int($0))) }
                        ),
                        in: 5...75
                    )
                    .controlSize(.small)
                }

                // Extra-variants table — generates side-by-side stacks at
                // different keep-counts/percentages, each in its own subdir.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Extra stacks (subfolders f# / p#)")
                            .font(.caption)
                        Spacer()
                        if !app.luckyStack.variants.isEmpty {
                            Button("Clear") {
                                app.luckyStack.variants = LuckyStackVariants()
                            }
                            .controlSize(.mini)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("f")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 14, alignment: .leading)
                        ForEach(0..<3, id: \.self) { i in
                            VariantField(
                                value: Binding(
                                    get: { app.luckyStack.variants.absoluteCounts[i] },
                                    set: { app.luckyStack.variants.absoluteCounts[i] = max(0, $0) }
                                ),
                                placeholder: "frames"
                            )
                        }
                    }
                    HStack(spacing: 4) {
                        Text("p")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 14, alignment: .leading)
                        ForEach(0..<3, id: \.self) { i in
                            VariantField(
                                value: Binding(
                                    get: { app.luckyStack.variants.percentages[i] },
                                    set: { app.luckyStack.variants.percentages[i] = max(0, min(100, $0)) }
                                ),
                                placeholder: "%"
                            )
                        }
                    }
                    Text("Each non-zero entry runs an extra stack and writes to e.g. ‘f100/’ or ‘p25/’ in the output folder. 0 = off.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // AutoNuke master toggle — single source of truth for
                // "let the engine decide". When ON the manual controls
                // below grey out: auto-PSF, auto-keep-%, AutoAP grid +
                // patch + multi-AP yes/no gate all kick in together
                // and the engine picks per-data values. When OFF every
                // checkbox / slider below is honoured exactly as the
                // user set it (no implicit auto behaviour). Replaced
                // the old one-shot Smart-auto button which only nudged
                // a few flags and left the rest editable, producing
                // the conflict-of-controls confusion the user flagged.
                HStack {
                    Spacer()
                    Toggle(isOn: $app.luckyStack.autoNuke) {
                        Label(
                            app.luckyStack.autoNuke ? "AutoNuke ON" : "AutoNuke",
                            systemImage: "wand.and.stars"
                        )
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
                            .background(autoNukeBackground)
                            .clipShape(Capsule())
                            .shadow(color: Color.purple.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .help("AutoNuke ON: engine picks auto-PSF, auto-keep-%, AP grid + patch, and multi-AP yes/no per data. Manual controls below grey out. Toggle off to configure by hand. The auto picks beat the hand-tuned presets on every fixture in the regression set.")
                    Spacer()
                }
                .padding(.vertical, 2)

                // Manual-controls block. AutoNuke ON disables every
                // checkbox / slider in here so the user can't accidentally
                // contradict the engine's auto picks. Run button and
                // queue status (below) stay live regardless.
                Group {
                if app.luckyStack.mode == .scientific {
                    HStack(spacing: 4) {
                        Toggle("Multi-AP", isOn: Binding(
                            get: { app.luckyStack.multiAP.enabled },
                            set: { newOn in
                                if newOn {
                                    if app.luckyStack.multiAP.grid == 0 {
                                        // 16×16 default (was 8×8). User bracket
                                        // on solar Hα 2026-05-01 picked the
                                        // finest grid as cleanest — finer cells
                                        // mean adjacent per-AP shifts vary
                                        // smoothly, hiding the cell-boundary
                                        // ramps that 8×8 left visible after
                                        // wavelet sharpening.
                                        app.luckyStack.multiAP = .grid(16, 16)
                                    }
                                } else {
                                    app.luckyStack.multiAP = .off
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        Text(app.luckyStack.multiAP.label)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .help("Local alignment-point grid for non-uniform seeing. Grid + patch size pull from the active preset; user presets remember your tuning.")

                    if app.luckyStack.multiAP.enabled {
                        // Auto badge — visible when AutoAP is active. Touching
                        // either slider below flips `userOverride = true` and
                        // the badge disappears for the rest of the session.
                        if !app.luckyStack.multiAP.userOverride {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                                    .foregroundColor(.accentColor)
                                Text("AUTO — grid + patch chosen from reference frame on each stack")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Reset") {
                                    app.luckyStack.multiAP.userOverride = false
                                }
                                .controlSize(.mini)
                                .help("Drop manual override; AutoAP picks grid + patch on next stack.")
                            }
                            .padding(.vertical, 1)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("AP grid").font(.caption)
                                Spacer()
                                Text("\(app.luckyStack.multiAP.grid)×\(app.luckyStack.multiAP.grid)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(app.luckyStack.multiAP.grid) },
                                    set: {
                                        app.luckyStack.multiAP.grid = max(2, min(20, Int($0)))
                                        app.luckyStack.multiAP.userOverride = true
                                    }
                                ),
                                in: 2...20, step: 1
                            )
                            .controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Patch size").font(.caption)
                                Spacer()
                                Text("\(app.luckyStack.multiAP.patchHalf * 2) px")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(app.luckyStack.multiAP.patchHalf) },
                                    set: {
                                        app.luckyStack.multiAP.patchHalf = max(4, min(48, Int($0)))
                                        app.luckyStack.multiAP.userOverride = true
                                    }
                                ),
                                in: 4...48, step: 1
                            )
                            .controlSize(.small)
                        }
                    }

                    // Sigma-clipped accumulator (Block B.1). Scientific-
                    // mode only because it doubles GPU work (Welford pass
                    // + clipped re-mean pass) and only helps when there
                    // are visible per-pixel outliers — cosmic ray hits,
                    // satellite trails, single-frame seeing spikes.
                    // AS!4 / RegiStax default σ=2.5; tighter (σ=2.0)
                    // clips harder, looser (σ=3.0) only catches obvious
                    // outliers.
                    HStack(spacing: 4) {
                        Toggle("Sigma-clip", isOn: $app.luckyStack.sigmaClipEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        if app.luckyStack.sigmaClipEnabled {
                            Spacer()
                            Text("σ")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f", app.luckyStack.sigmaClipThreshold))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .help("Two-pass accumulator: per-pixel mean + variance, then re-mean only samples within σ × stddev. Clips outlier frames per-pixel (cosmic rays, satellite trails, single-frame seeing spikes) without rejecting the whole frame. ~2× the GPU cost of the unclipped accumulator. AS!4 / RegiStax default σ=2.5.")

                    if app.luckyStack.sigmaClipEnabled {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Threshold").font(.caption)
                                Spacer()
                                Text(String(format: "%.1f σ", app.luckyStack.sigmaClipThreshold))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: $app.luckyStack.sigmaClipThreshold,
                                in: 1.5...4.0, step: 0.1
                            )
                            .controlSize(.small)
                        }
                    }

                    // Drizzle reconstruction (B.6). Scale 1 = off (no
                    // upsample); 2 or 3 splats each input pixel onto an
                    // upsampled accumulator with sub-pixel precision
                    // driven by the alignment shifts. Useful on
                    // undersampled subjects (FWHM < 2.4 × pixel scale)
                    // — lunar / solar surface at long focal length, or
                    // tight planetary captures. AA pre-filter is NOT
                    // yet implemented (Drizzle.swift CPU + GPU paths
                    // splat raw input pixels), so keep an eye out for
                    // grid-moiré on very sparse alignment shifts.
                    HStack(spacing: 4) {
                        Text("Drizzle")
                            .font(.system(size: 11))
                        Spacer()
                        Picker("", selection: $app.luckyStack.drizzleScale) {
                            Text("Off").tag(1)
                            Text("2×").tag(2)
                            Text("3×").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                    }
                    .help("Variable-pixel linear reconstruction (Fruchter & Hook). Splats each input pixel onto an upsampled accumulator (2× or 3×) using the alignment shifts as sub-pixel offsets. Useful on undersampled captures where seeing FWHM is below 2.4 × pixel scale. Keep at Off when source is already well-sampled — drizzle adds memory pressure without improving the result.")

                    if app.luckyStack.drizzleScale > 1 {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Pixfrac").font(.caption)
                                Spacer()
                                Text(String(format: "%.2f", app.luckyStack.drizzlePixfrac))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: $app.luckyStack.drizzlePixfrac,
                                in: 0.3...1.0, step: 0.05
                            )
                            .controlSize(.small)
                        }
                        .help("Drop size as a fraction of the input pixel. BiggSky default 0.7. Lower = sharper but more dropouts on sparse keep-% runs; higher = smoother but blurrier output.")

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("AA σ").font(.caption)
                                Spacer()
                                Text(app.luckyStack.drizzleAASigma > 0
                                     ? String(format: "%.2f px", app.luckyStack.drizzleAASigma)
                                     : "off")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: $app.luckyStack.drizzleAASigma,
                                in: 0.0...2.0, step: 0.1
                            )
                            .controlSize(.small)
                        }
                        .help("Anti-aliasing pre-filter applied to each frame before splat. Smooths the splat-drop hard edges so they don't beat with the underlying signal — the BiggSky-warned grid-moiré protection. Default 0.7 input-pixels (matches pixfrac). 0 disables, restoring pre-AA splat behaviour.")
                    }
                }

                // Per-channel stacking (Path B). Bayer-only — mono SER
                // captures ignore the flag and use the standard runner.
                // Experimental — see tooltip.
                HStack(spacing: 4) {
                    Toggle("Per-channel (experimental)", isOn: $app.luckyStack.perChannelStacking)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .help("Experimental: split Bayer SER into R/G/B planes, align + stack each independently. Catches per-frame chromatic dispersion at low altitudes (< 30°). Half-res extract + bilinear-upsample combine softens the output by ~1 px vs. the standard demosaic path — only enable when the chromatic-dispersion correction is actually needed. Bayer captures only. ~3× runtime cost.")

                // Auto-PSF post-pass (Block C.1 v0).
                HStack(spacing: 4) {
                    Toggle("Auto-PSF + Wiener", isOn: $app.luckyStack.autoPSF)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    if app.luckyStack.autoPSF {
                        Spacer()
                        Text("SNR")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("\(Int(app.luckyStack.autoPSFSNR))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .help("Estimates Gaussian PSF sigma from the planetary limb and applies Wiener deconvolution. Skipped silently if no clear disc edge is present in the stacked output. Use lower SNR (~30) for aggressive sharpening, higher (~100) for soft results on noisy data.")

                if app.luckyStack.autoPSF {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Wiener SNR").font(.caption)
                            Spacer()
                            Text("\(Int(app.luckyStack.autoPSFSNR))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: $app.luckyStack.autoPSFSNR,
                            in: 20...200, step: 10
                        )
                        .controlSize(.small)
                    }

                    // Radial Fade Filter (RFF). Auto = σ-aware formula.
                    // Manual = expose inner / outer sliders. Off = skip the
                    // fade entirely (raw Wiener output) — for solar Hα
                    // where the auto fade looks strange against the
                    // chromosphere edge.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Radial Fade").font(.caption)
                            Spacer()
                            Picker("", selection: $app.luckyStack.rffMode) {
                                ForEach(RFFMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                            .controlSize(.small)
                            .labelsHidden()
                        }
                        if app.luckyStack.rffMode == .manual {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("RFF Inner").font(.caption2)
                                    Spacer()
                                    Text(String(format: "%.2f", app.luckyStack.rffInnerFraction))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: $app.luckyStack.rffInnerFraction,
                                    in: 0.5...1.5, step: 0.05
                                )
                                .controlSize(.small)
                                HStack {
                                    Text("RFF Outer").font(.caption2)
                                    Spacer()
                                    Text(String(format: "%.2f", app.luckyStack.rffOuterFraction))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: $app.luckyStack.rffOuterFraction,
                                    in: 1.0...2.0, step: 0.05
                                )
                                .controlSize(.small)
                            }
                        }
                    }
                    .help("Radial Fade Filter blends Wiener-deconv output with the bare stack near the disc limb to suppress Gibbs ringing. Auto picks per-disc fractions from σ/r. Manual exposes the inner / outer fractions. Off skips the fade — useful when the auto behaviour looks wrong on certain limb shapes (solar Hα chromosphere).")

                    // Block C.5 dual-stage denoise — visible only when
                    // auto-PSF is on, since the engine ignores these
                    // values otherwise.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Denoise (PSF estimate)").font(.caption)
                            Spacer()
                            Text("\(app.luckyStack.denoisePrePercent)%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(app.luckyStack.denoisePrePercent) },
                                set: { app.luckyStack.denoisePrePercent = Int($0) }
                            ),
                            in: 0...100, step: 5
                        )
                        .controlSize(.small)
                    }
                    .help("Wavelet soft-threshold applied before the PSF estimate + Wiener deconv. Cleans up the LSF measurement and prevents the inverse filter from amplifying noise. BiggSky-typical 75. Set to 0 for clean low-noise SERs.")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Denoise (After restore)").font(.caption)
                            Spacer()
                            Text("\(app.luckyStack.denoisePostPercent)%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(app.luckyStack.denoisePostPercent) },
                                set: { app.luckyStack.denoisePostPercent = Int($0) }
                            ),
                            in: 0...100, step: 5
                        )
                        .controlSize(.small)
                    }
                    .help("Wavelet soft-threshold applied after the Wiener restore. Suppresses residual ringing and amplified noise from the deconvolution. BiggSky-typical 75. Set to 1 for low-noise sources.")

                    // Block C.3 — tiled deconv with green/yellow/red mask.
                    HStack(spacing: 4) {
                        Toggle("Tiled deconv (mask bg)", isOn: $app.luckyStack.tiledDeconv)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        if app.luckyStack.tiledDeconv {
                            Spacer()
                            Text("\(app.luckyStack.tiledDeconvAPGrid)×\(app.luckyStack.tiledDeconvAPGrid)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .help("Classifies each AP cell green/yellow/red. Background tiles skip deconv (no noise amplification), limb tiles get half-strength, surface tiles get full strength. The big BiggSky-documented benefit when stacking has visible noise floor in dark regions.")

                    if app.luckyStack.tiledDeconv {
                        Slider(
                            value: Binding(
                                get: { Double(app.luckyStack.tiledDeconvAPGrid) },
                                set: { app.luckyStack.tiledDeconvAPGrid = Int($0) }
                            ),
                            in: 4...16, step: 1
                        )
                        .controlSize(.small)
                    }
                }

                // D.1 — pre-stack calibration master frames (commit
                // wired 2026-05-01). Both pickers accept a pre-built
                // master TIFF; engine subtracts dark + divides by
                // normalised flat at decode time, before quality
                // grading + alignment. Folder-scan master derivation
                // is a v1+ helper (current design assumes the
                // PixInsight / ASTAP workflow where users pre-build
                // their masters externally).
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Calibration")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        if app.luckyStack.masterDarkURL != nil
                            || app.luckyStack.masterFlatURL != nil {
                            Text("active")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        }
                    }
                    CalibrationMasterPicker(
                        label: "Dark",
                        url: $app.luckyStack.masterDarkURL,
                        help: "Optional master dark TIFF. Subtracted from every frame before quality grading + alignment, so quality scores see the dark-corrected image. Build the master in PixInsight / ASTAP / Siril by averaging N dark frames at the same exposure + sensor temperature. Same dimensions as the source SER required — engine logs + drops a mismatched master without crashing."
                    )
                    CalibrationMasterPicker(
                        label: "Flat",
                        url: $app.luckyStack.masterFlatURL,
                        help: "Optional master flat TIFF. Each frame is divided by the normalised flat to correct vignetting + dust shadows. Especially valuable for solar Hα where Newton ring patterns and uneven etalon illumination would otherwise survive into the stacked output. Same dimensions as the source SER required."
                    )
                }

                Picker("Filename", selection: $app.luckyStack.filenameMode) {
                    ForEach(LuckyStackFilenameMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .help("SharpCap: keep original name + _stack. WinJUPOS: YYYY-MM-DD-HHmm_ss-<target>.tif from the SER UTC timestamp.")

                if app.luckyStack.filenameMode == .winjupos {
                    HStack(spacing: 4) {
                        Text("Target").font(.caption)
                        TextField("", text: $app.luckyStack.winjuposTarget)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(maxWidth: 100)
                    }
                }

                }
                .disabled(app.luckyStack.autoNuke)
                .opacity(app.luckyStack.autoNuke ? 0.45 : 1.0)

                if app.luckyStack.autoNuke {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text("Manual controls inactive — engine picks per-data values. Toggle AutoNuke off to configure by hand.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                Divider()

                // Bake-in + auto-tone are output-style choices independent
                // of AutoNuke (which controls stacking quality decisions).
                // Always interactive so the user can pick whether to bake
                // their live Sharpen + Tone settings into the saved file
                // or apply a subject-aware tone gamma — orthogonal to
                // whether the engine picks the multi-AP geometry.
                Toggle("Bake current Sharpen + Tone into output", isOn: $app.luckyStack.bakeInProcessing)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("ON: the saved TIFF is the stacked frame run through the active Sharpen + Tone Curve settings — matches what you see in the live preview. OFF (default): write the raw stacked mean and apply Sharpen later via 'Apply to Selection' on the OUTPUTS tab. Independent of AutoNuke — bake-in is an output-style choice.")

                Toggle("Auto-tone (subject-aware)", isOn: $app.luckyStack.autoRecoverDynamicRange)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("ON: apply a subject-aware tone adjust to the saved file. Lunar / solar / textured stacks (median ≥ 0.30) pass through unchanged. Planetary / dark-dominated stacks (median < 0.30) get gamma 1.3 — a pure midtone compression that pulls bright planet bodies down without clamping or destroying detail. OFF (default 2026-05-02): write the bare accumulator output for every subject. Independent of AutoNuke — tone choice is yours.")

                // What's actually going to land in the saved TIFF? Show
                // the user a one-line summary so they can verify before
                // running. Catches the "I deselected everything but it
                // still looks sharpened" failure mode by exposing the
                // truth: auto-PSF + bake-in are the two paths that
                // sharpen the saved file.
                savedFilePipelineSummary

                LuckyRunButton(disabled: serCount == 0) {
                    app.runLuckyStackOnSelection()
                }
                .help("Stacks every marked or selected .ser file. Output goes to the configured Output Folder.")

                Text(hintLine)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Status rows for any in-flight or completed lucky-stack queue items.
                if !app.luckyStack.queue.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(app.luckyStack.queue) { item in
                            QueueRow(item: item)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            // Matches SectionContainer's card fill so the Lucky Stack
            // section reads as the same visual unit as Sharpening /
            // Stabilize / Tone Curve. No active-stage accent here —
            // Lucky Stack is a batch-level run, not a live-preview
            // pipeline stage, so the highlight overlay isn't relevant.
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07))
        )
    }

    private var targetCountLabel: String {
        if allSerInCatalog == 0 { return "no SER" }
        return "\(serCount)/\(allSerInCatalog) SER"
    }

    private var hintLine: String {
        if allSerInCatalog == 0 {
            return "No .ser files in the open folder. Open a folder with SharpCap captures (⌘O) to begin."
        }
        if serCount == 0 {
            return "Mark or select the .ser files you want to stack in the file list."
        }
        return "Will write \(serCount) stacked TIFF\(serCount == 1 ? "" : "s") to the output folder."
    }
}

/// Compact integer text field for the variants table. Stores 0 as "off"
/// (rendered as empty placeholder).
private struct VariantField: View {
    @Binding var value: Int
    let placeholder: String
    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 64)
            .multilineTextAlignment(.center)
            .onAppear { text = value == 0 ? "" : String(value) }
            .onChange(of: value) { _, new in
                let want = new == 0 ? "" : String(new)
                if text != want { text = want }
            }
            .onChange(of: text) { _, new in
                let n = Int(new.trimmingCharacters(in: .whitespaces)) ?? 0
                if value != n { value = n }
            }
    }
}

/// Generic hero "run" button — used by both Lucky Stack and Run Stabilize.
/// A layered SF-Symbol icon + sparkles overlay + purple→pink gradient.
struct LuckyRunButton: View {
    let disabled: Bool
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    @State private var hover = false

    init(
        disabled: Bool,
        title: String = "Run Lucky Stack",
        subtitle: String = "✨  best frames → one stacked TIFF",
        icon: String = "square.3.layers.3d.top.filled",
        action: @escaping () -> Void
    ) {
        self.disabled = disabled
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white)
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.yellow)
                        .offset(x: 12, y: -8)
                }
                .frame(width: 28, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: disabled
                        ? [Color.gray.opacity(0.5), Color.gray.opacity(0.3)]
                        : [Color(red: 0.45, green: 0.15, blue: 0.95),
                           Color(red: 0.95, green: 0.30, blue: 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(hover ? 0.30 : 0.10), lineWidth: 1)
            )
            .shadow(color: disabled ? .clear : Color.purple.opacity(0.35), radius: hover ? 6 : 3, x: 0, y: 1)
            .scaleEffect(hover && !disabled ? 1.015 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .onHover { hover = $0 }
    }
}

private struct QueueRow: View {
    let item: LuckyStackItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                statusIcon
                Text(item.url.lastPathComponent)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(item.statusText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if item.status == .processing {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle").foregroundColor(.secondary)
        case .processing:
            Image(systemName: "circle.dotted").foregroundColor(.accentColor)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
        }
    }
}

/// File picker row for a calibration master frame (D.1). Compact
/// label + Choose / filename button + clear button. Uses NSOpenPanel
/// directly because the section needs to write to a `URL?` binding,
/// which SwiftUI's `.fileImporter` doesn't bind cleanly to without
/// a wrapping `Optional` adapter.
private struct CalibrationMasterPicker: View {
    let label: String
    @Binding var url: URL?
    let help: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 32, alignment: .leading)
                .foregroundColor(.secondary)

            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.tiff, .png, .jpeg]
                panel.prompt = "Use as \(label.lowercased())"
                if panel.runModal() == .OK, let picked = panel.url {
                    url = picked
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: url == nil ? "tray" : "tray.fill")
                        .font(.system(size: 9))
                    Text(url?.lastPathComponent ?? "Choose master \(label.lowercased())…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .controlSize(.small)
            .help(help)

            if url != nil {
                Button {
                    url = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Clear master \(label.lowercased())")
            }
        }
    }
}
