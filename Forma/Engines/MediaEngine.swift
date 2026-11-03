import Foundation

/// Audio & video through FFmpeg, tuned for Apple Silicon: VideoToolbox decode + encode (media engines),
/// AudioToolbox AAC, instant remux when no re-encode is needed, automatic software fallback.
enum MediaEngine {

    struct Job: Sendable {
        var input: URL
        var inputKind: MediaKind
        var format: FormatDescriptor
        var video: VideoSettings
        var audio: AudioSettings
        var image: ImageSettings        // watermark / metadata
        var mode: ProcessMode
        var compress: Bool
        var near: URL
    }

    // MARK: Probe

    struct Probe: Sendable {
        var duration: Double = 0
        var videoCodec: String?
        var width = 0, height = 0
        var fps: Double = 0
        var audioCodec: String?
        var audioChannels = 0
        var sampleRate = 0
        var hasCoverArt = false
        var hasSubtitles = false
        var bitrate = 0
        var tags: [String: String] = [:]
    }

    static func probe(_ url: URL) async -> Probe {
        var p = Probe()
        guard Tool.ffprobe.isAvailable,
              let r = try? await ProcessRunner.run(Tool.ffprobe.path!, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path], timeout: 30),
              let json = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any] else { return p }
        if let f = json["format"] as? [String: Any] {
            p.duration = Double(f["duration"] as? String ?? "") ?? 0
            p.bitrate = Int(f["bit_rate"] as? String ?? "") ?? 0
            p.tags = (f["tags"] as? [String: String]) ?? [:]
        }
        for s in (json["streams"] as? [[String: Any]]) ?? [] {
            let type = s["codec_type"] as? String
            let disp = s["disposition"] as? [String: Any]
            let attached = (disp?["attached_pic"] as? Int) == 1
            if type == "video" && attached { p.hasCoverArt = true; continue }
            if type == "video" && p.videoCodec == nil {
                p.videoCodec = s["codec_name"] as? String
                p.width = s["width"] as? Int ?? 0
                p.height = s["height"] as? Int ?? 0
                if let r = s["avg_frame_rate"] as? String {
                    let parts = r.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0 { p.fps = parts[0] / parts[1] }
                }
                if p.duration == 0 { p.duration = Double(s["duration"] as? String ?? "") ?? 0 }
            } else if type == "audio" && p.audioCodec == nil {
                p.audioCodec = s["codec_name"] as? String
                p.audioChannels = s["channels"] as? Int ?? 0
                p.sampleRate = Int(s["sample_rate"] as? String ?? "") ?? 0
                if p.duration == 0 { p.duration = Double(s["duration"] as? String ?? "") ?? 0 }
            } else if type == "subtitle" { p.hasSubtitles = true }
        }
        return p
    }

    // MARK: Entry

    static func process(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard Tool.ffmpeg.isAvailable else { throw ToolError("FFmpeg n'est pas installé — `brew install ffmpeg`.") }
        let info = await probe(job.input)
        if job.format.kind == .audio && info.audioCodec == nil && job.inputKind == .video {
            throw ToolError("Cette vidéo n'a pas de piste audio à extraire.")
        }
        let out = OutputResolver.tempURL(ext: job.format.ext, near: job.near)
        let duration = max(0.01, effectiveDuration(info.duration, job.video))

        // 1) Instant remux when possible (MOV → MP4, MKV → MP4 …)
        if let remux = remuxArguments(job, info: info, out: out) {
            if (try? await run(remux, duration: duration, progress: progress)) != nil, out.fileSize > 0 { return out }
            try? FileManager.default.removeItem(at: out)
        }
        // 2) Hardware encode, 3) software fallback
        let hw = job.video.hardwareAcceleration
        do {
            try await run(try arguments(job, info: info, out: out, hardware: hw), duration: duration, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard hw, job.format.kind == .video else { throw error }
            try? FileManager.default.removeItem(at: out)
            progress(0)
            try await run(try arguments(job, info: info, out: out, hardware: false), duration: duration, progress: progress)
        }
        guard out.fileSize > 0 else { throw ToolError("Le fichier de sortie n'a pas été créé.") }
        return out
    }

    static func effectiveDuration(_ d: Double, _ v: VideoSettings) -> Double {
        var d = d
        if let e = v.trimEnd { d = min(d, e) }
        if let s = v.trimStart { d -= s }
        return d / max(0.25, v.playbackSpeed)
    }

    private static func run(_ args: [String], duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ProcessRunner.check(.ffmpeg, args, timeout: 6 * 3600) { line in
            if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="), let v = Double(line.split(separator: "=").last ?? "") {
                progress(min(0.99, (v / 1_000_000) / duration))
            }
        }
    }

    // MARK: Remux

    static func remuxArguments(_ job: Job, info: Probe, out: URL) -> [String]? {
        guard job.mode == .convert, !job.compress, job.format.kind == .video,
              case .video(let container, let forcedV, let forcedA, let extra) = job.format.writer,
              let vcodec = info.videoCodec, job.video.resolution == .original, job.video.frameRate == nil,
              job.video.playbackSpeed == 1, job.video.trimStart == nil, job.video.trimEnd == nil,
              !job.video.burnSubtitles, !(job.image.watermark.enabled && job.image.watermark.applyToVideos) else { return nil }
        if let forcedV, normalizedCodec(forcedV) != vcodec { return nil }
        let ok: [String: Set<String>] = [
            "mp4": ["h264", "hevc", "av1", "mpeg4"], "mov": ["h264", "hevc", "prores", "mpeg4", "mjpeg"], "ipod": ["h264", "hevc"],
            "matroska": ["h264", "hevc", "av1", "vp9", "vp8", "mpeg4", "mpeg2video", "prores", "theora"], "webm": ["vp8", "vp9", "av1"],
            "mpegts": ["h264", "hevc", "mpeg2video"], "avi": ["h264", "mpeg4", "mjpeg"], "flv": ["h264"], "f4v": ["h264"],
            "3gp": ["h264"], "3g2": ["h264"],
        ]
        guard let c = container, ok[c]?.contains(vcodec) == true else { return nil }
        var args = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", "-i", job.input.path,
                    "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"]
        let audioOK: [String: Set<String>] = ["mp4": ["aac", "mp3", "alac", "ac3", "eac3", "opus", "flac"], "mov": ["aac", "mp3", "alac", "pcm_s16le", "pcm_s24le", "ac3"],
                                              "ipod": ["aac", "alac"], "matroska": [], "webm": ["opus", "vorbis"], "mpegts": ["aac", "mp3", "ac3", "mp2"]]
        if forcedA == "-" { args += ["-an"] }
        else if let a = info.audioCodec, c == "matroska" || audioOK[c]?.contains(a) == true { args += ["-c:a", "copy"] }
        else { args += audioCodecArgs(defaultAudio(container: c, forced: forcedA), settings: job.audio, bitrate: job.video.audioBitrate) }
        if vcodec == "hevc" && ["mp4", "mov", "ipod"].contains(c) { args += ["-tag:v", "hvc1"] }
        args += ["-map_metadata", job.image.metadata == .stripAll ? "-1" : "0"]
        args += extra.filter { $0 != "-tag:v" && $0 != "hvc1" }
        args += ["-f", c, out.path]
        return args
    }

    static func normalizedCodec(_ c: String) -> String {
        ["libx264": "h264", "libx265": "hevc", "libvpx-vp9": "vp9", "libtheora": "theora", "prores": "prores", "vp9": "vp9", "h264": "h264", "hevc": "hevc"][c] ?? c
    }

    // MARK: Full encode

    static func arguments(_ job: Job, info: Probe, out: URL, hardware: Bool) throws -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats"]
        let isVideoIn = job.inputKind == .video
        if isVideoIn && hardware { a += ["-hwaccel", "videotoolbox"] }
        if let s = job.video.trimStart, s > 0 { a += ["-ss", String(format: "%.3f", s)] }
        if let e = job.video.trimEnd { a += ["-to", String(format: "%.3f", e)] }
        a += ["-i", job.input.path]
        var inputCount = 1

        switch job.format.writer {
        case .animated(let kind):
            a += animatedArgs(kind: kind, job: job)
            a += [out.path]
            return a

        case .audio(let codec, let muxer, let extra):
            // Cover art: keep embedded, or pick cover.jpg/folder.jpg from the folder.
            let coverCapable = ["MP3", "M4A", "AAC", "ALAC", "M4R", "FLAC"].contains(job.format.id)
            var coverInput: Int?
            if coverCapable && !info.hasCoverArt && job.audio.embedCoverArt, let cover = folderCover(near: job.input) {
                a += ["-i", cover.path]; coverInput = inputCount; inputCount += 1
            }
            a += ["-map", "0:a:0"]
            if coverCapable && info.hasCoverArt && !isVideoIn {
                a += ["-map", "0:v?", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
            } else if let ci = coverInput {
                a += ["-map", "\(ci):v", "-c:v", job.format.id == "FLAC" ? "png" : "mjpeg", "-disposition:v:0", "attached_pic"]
            } else {
                a += ["-vn"]
            }
            a += audioCodecArgs(codec, settings: job.audio, bitrate: nil, compress: job.compress)
            var af: [String] = []
            if job.video.playbackSpeed != 1 { af += atempo(job.video.playbackSpeed) }
            if job.audio.normalize { af.append("loudnorm=I=-16:TP=-1.5:LRA=11") }
            if !af.isEmpty { a += ["-af", af.joined(separator: ",")] }
            if let sr = job.audio.sampleRate { a += ["-ar", "\(sr)"] }
            else if codec == "libopus" { a += ["-ar", "48000"] }
            if job.audio.effectiveMono { a += ["-ac", "1"] }
            a += ["-map_metadata", job.image.metadata == .stripAll ? "-1" : "0"]
            a += extra
            if let muxer { a += ["-f", muxer] }
            a += [out.path]
            return a

        case .video(let container, let forcedV, let forcedA, let extra):
            // Sidecar subtitles (movie.srt / movie.vtt / movie.fr.srt …)
            let sub = job.video.autoAttachSubtitles ? sidecarSubtitle(for: job.input) : nil
            var subInput: Int?
            if let sub, !job.video.burnSubtitles { a += ["-i", sub.path]; subInput = inputCount; inputCount += 1 }
            var wmInput: Int?
            if job.image.watermark.enabled, job.image.watermark.applyToVideos, let p = job.image.watermark.imagePath {
                a += ["-i", p]; wmInput = inputCount; inputCount += 1
            }

            // Video filters
            var vf: [String] = []
            if let h = job.video.resolution.height, info.height > h { vf.append("scale=-2:\(h):flags=lanczos") }
            if let fps = job.video.frameRate, info.fps == 0 || Double(fps) < info.fps { vf.append("fps=\(fps)") }
            if job.video.playbackSpeed != 1 { vf.append("setpts=PTS/\(job.video.playbackSpeed)") }
            if job.video.burnSubtitles, let sub { vf.append("subtitles='\(sub.path.replacingOccurrences(of: "'", with: "\\'"))'") }
            let codecName = videoEncoder(job: job, forced: forcedV, hardware: hardware)
            if codecName == "libx264" || codecName == "h264_videotoolbox" || codecName == "mpeg2video" || codecName == "wmv2" { vf.append("format=yuv420p") }

            if let wi = wmInput {
                let w = job.image.watermark
                let base = vf.isEmpty ? "[0:v]null" : "[0:v]" + vf.joined(separator: ",")
                let (x, y) = overlayPosition(w)
                let fc = "\(base)[base];[\(wi):v]format=rgba,colorchannelmixer=aa=\(w.opacity)[wm0];[wm0][base]scale2ref=w=main_w*\(w.relativeSize):h=ow/mdar[wm][b2];[b2][wm]overlay=\(x):\(y)[vout]"
                a += ["-filter_complex", fc, "-map", "[vout]"]
            } else {
                a += ["-map", "0:v:0"]
                if !vf.isEmpty { a += ["-vf", vf.joined(separator: ",")] }
            }
            a += videoCodecArgs(codecName, job: job)

            // Audio
            let audioCodec = defaultAudio(container: container ?? "mp4", forced: forcedA)
            if job.video.removeAudio || forcedA == "-" || info.audioCodec == nil {
                a += ["-an"]
            } else {
                a += ["-map", "0:a:0?"]
                a += audioCodecArgs(audioCodec, settings: job.audio, bitrate: job.video.audioBitrate)
                if job.video.playbackSpeed != 1 { a += ["-af", atempo(job.video.playbackSpeed).joined(separator: ",")] }
            }
            // Soft subtitles
            if let si = subInput {
                let sc = ["mp4": "mov_text", "mov": "mov_text", "ipod": "mov_text", "matroska": "srt", "webm": "webvtt"][container ?? ""]
                if let sc { a += ["-map", "\(si):s", "-c:s", sc] }
            }
            a += ["-map_metadata", job.image.metadata == .stripAll ? "-1" : "0", "-max_muxing_queue_size", "4096"]
            if (codecName.contains("hevc") || codecName == "libx265"), ["mp4", "mov", "ipod"].contains(container ?? "") { a += ["-tag:v", "hvc1"] }
            a += extra.filter { $0 != "-tag:v" && $0 != "hvc1" }
            if let container { a += ["-f", container] }
            a += [out.path]
            return a

        default:
            throw ToolError("Format de sortie incompatible avec ce média.")
        }
    }

    static func videoEncoder(job: Job, forced: String?, hardware: Bool) -> String {
        let codec: VideoCodec?
        switch forced {
        case nil: codec = job.compress ? job.video.effectiveCodec : job.video.codec
        case "h264": codec = .h264
        case "hevc": codec = .hevc
        case "vp9": codec = .vp9
        case "prores": codec = .prores
        default: return forced!
        }
        guard let codec else { return "libx264" }
        if hardware, let hw = codec.hardware { return hw }
        return codec.software
    }

    static func videoCodecArgs(_ enc: String, job: Job) -> [String] {
        let q = job.compress ? job.video.effectiveQuality : max(job.video.quality, 70)
        let speed = job.video.speed
        switch enc {
        case "h264_videotoolbox", "hevc_videotoolbox":
            // Constant-quality mode of Apple's media engine; realtime off for best quality.
            var a = ["-c:v", enc, "-q:v", "\(max(1, min(100, q)))", "-allow_sw", "1", "-realtime", "0"]
            if enc == "hevc_videotoolbox" { a += ["-profile:v", "main"] }
            return a
        case "prores_videotoolbox": return ["-c:v", enc, "-profile:v", "2"]
        case "prores_ks": return ["-c:v", enc, "-profile:v", "2", "-vendor", "apl0"]
        case "libx264": return ["-c:v", enc, "-crf", "\(Int(40 - Double(q) * 0.24))", "-preset", speed.rawValue]
        case "libx265": return ["-c:v", enc, "-crf", "\(Int(42 - Double(q) * 0.24))", "-preset", speed.rawValue, "-x265-params", "log-level=error"]
        case "libsvtav1": return ["-c:v", enc, "-crf", "\(Int(55 - Double(q) * 0.33))", "-preset", "\(speed.svtPreset)"]
        case "libvpx-vp9": return ["-c:v", enc, "-crf", "\(Int(55 - Double(q) * 0.3))", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "\(speed.vpxSpeed)"]
        case "libtheora": return ["-c:v", enc, "-q:v", "\(max(1, min(10, q / 10)))"]
        default: return ["-c:v", enc, "-q:v", "\(max(2, min(31, Int(31 - Double(q) * 0.29))))"]
        }
    }

    static func defaultAudio(container: String, forced: String?) -> String {
        if let forced, forced != "-" { return forced }
        switch container {
        case "webm", "ogg": return "libopus"
        case "matroska": return "libopus"
        case "mpegts": return "aac"
        default: return "aac_at"
        }
    }

    static func audioCodecArgs(_ codec: String, settings s: AudioSettings, bitrate: Int?, compress: Bool = false) -> [String] {
        let br = bitrate ?? s.effectiveBitrate
        var a = ["-c:a", codec]
        switch codec {
        case "libmp3lame":
            switch s.mode {
            case .cbr: a += ["-b:a", "\(br)k"]
            case .abr: a += ["-b:a", "\(br)k", "-abr", "1"]
            case .vbr: a += ["-q:a", "\(max(0, min(9, Int((320 - Double(br)) / 32))))"]
            }
        case "aac_at", "aac":
            a += ["-b:a", "\(br)k"]
            if codec == "aac_at" { a += ["-aac_at_mode", s.mode == .cbr ? "cbr" : s.mode == .abr ? "abr" : "cvbr", "-aac_at_quality", "0"] }
        case "libopus": a += ["-b:a", "\(min(br, 256))k", "-vbr", s.mode == .cbr ? "off" : s.mode == .abr ? "constrained" : "on"]
        case "libvorbis":
            if s.mode == .vbr { a += ["-q:a", "\(max(0, min(10, br / 32)))"] } else { a += ["-b:a", "\(br)k"] }
        case "ac3", "eac3", "mp2", "wmav2", "dca": a += ["-b:a", "\(max(br, codec == "dca" ? 768 : 96))k"]
        default: break // lossless / PCM
        }
        return a
    }

    static func atempo(_ speed: Double) -> [String] {
        var s = speed, parts: [String] = []
        while s > 2 { parts.append("atempo=2.0"); s /= 2 }
        while s < 0.5 { parts.append("atempo=0.5"); s /= 0.5 }
        parts.append("atempo=\(String(format: "%.4f", s))")
        return parts
    }

    static func scaleFilter(width: Int?) -> String {
        guard let width else { return "" }
        return "scale='min(\(width),iw)':-2:flags=lanczos,"
    }

    static func animatedArgs(kind: String, job: Job) -> [String] {
        let v = job.video
        var pre = "fps=\(v.gifFPS),scale='min(\(v.gifWidth),iw)':-2:flags=lanczos"
        if v.playbackSpeed != 1 { pre = "setpts=PTS/\(v.playbackSpeed)," + pre }
        switch kind {
        case "gif":
            return ["-filter_complex", "[0:v]\(pre),split[a][b];[a]palettegen=max_colors=\(v.gifColors):stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
                    "-loop", v.gifLoop ? "0" : "-1", "-an"]
        case "webp":
            return ["-vf", pre, "-c:v", "libwebp_anim", "-quality", "\(job.compress ? job.image.quality() : 80)", "-compression_level", "6", "-loop", v.gifLoop ? "0" : "1", "-an"]
        default:
            return ["-vf", pre, "-f", "apng", "-plays", v.gifLoop ? "0" : "1", "-an"]
        }
    }

    static func overlayPosition(_ w: WatermarkSettings) -> (String, String) {
        let m = "min(main_w\\,main_h)*\(w.margin)"
        let x: String, y: String
        switch w.position {
        case .topLeft, .left, .bottomLeft: x = m
        case .top, .center, .bottom, .tiled: x = "(main_w-overlay_w)/2"
        default: x = "main_w-overlay_w-\(m)"
        }
        switch w.position {
        case .topLeft, .top, .topRight: y = m
        case .left, .center, .right, .tiled: y = "(main_h-overlay_h)/2"
        default: y = "main_h-overlay_h-\(m)"
        }
        return (x, y)
    }

    static func sidecarSubtitle(for url: URL) -> URL? {
        let base = url.deletingPathExtension()
        let fm = FileManager.default
        for ext in ["srt", "vtt", "ass", "ssa"] {
            let c = base.appendingPathExtension(ext)
            if fm.fileExists(atPath: c.path) { return c }
        }
        // movie.fr.srt, movie.en.srt …
        let dir = url.deletingLastPathComponent()
        let name = base.lastPathComponent
        let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if let m = items.first(where: { $0.hasPrefix(name + ".") && ["srt", "vtt"].contains(($0 as NSString).pathExtension.lowercased()) }) {
            return dir.appendingPathComponent(m)
        }
        return nil
    }

    static func folderCover(near url: URL) -> URL? {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        for name in ["cover", "folder", "front", "artwork", "album", "Cover", "Folder", "Front", "AlbumArt"] {
            for ext in ["jpg", "jpeg", "png"] {
                let c = dir.appendingPathComponent(name).appendingPathExtension(ext)
                if fm.fileExists(atPath: c.path) { return c }
            }
        }
        return nil
    }
}
