import Foundation
import UniformTypeIdentifiers

/// Nature of a media file, as detected from its extension / UTType.
enum MediaKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case image, video, audio, document, office
    var id: String { rawValue }
    var label: String {
        switch self {
        case .image: "Images"
        case .video: "Vidéos"
        case .audio: "Audio"
        case .document: "PDF & vectoriels"
        case .office: "Documents"
        }
    }
    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.richtext"
        case .office: "doc.text"
        }
    }
    /// Kinds shown to the user (PDF / EPS sources are handled with the images).
    static let visible: [MediaKind] = [.image, .video, .audio, .office]
}

/// How an output format is produced. Native writers are always preferred (fastest, zero dependency).
enum Writer: Sendable {
    case native(String)                 // CGImageDestination UTType identifier
    case nativePDF                      // CGContext PDF (one page per image)
    case webp                           // cwebp → fallback magick
    case jxl                            // cjxl → fallback magick
    case magick(String)                 // ImageMagick coder (prefix)
    case animated(String)               // gif / apng / webp from video (ffmpeg) or frames (magick)
    case audio(codec: String, muxer: String?, extra: [String])
    case video(container: String?, forcedVideo: String?, forcedAudio: String?, extra: [String])
    case postscript(String)             // Ghostscript device (eps / ai)
    case office                         // text documents, spreadsheets, slides (OfficeEngine routes by format id)
}

struct FormatDescriptor: Identifiable, Hashable, Sendable {
    let id: String          // stable identifier, e.g. "JPEG"
    let ext: String         // output extension
    let name: String        // display name
    let detail: String      // short description shown in the picker
    let kind: MediaKind     // kind of the *output*
    let group: String
    let writer: Writer
    var popular: Bool = false

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var supportsQuality: Bool {
        switch writer {
        case .native(let t): ["public.jpeg", "public.heic", "public.avif", "public.jpeg-2000", "public.tiff"].contains(t)
        case .webp, .jxl: true
        case .magick(let c): ["JPG", "JPEG", "JP2", "MIFF"].contains(c)
        case .audio, .video, .animated: true
        default: false
        }
    }
    var supportsAlpha: Bool {
        !["JPEG", "BMP", "PBM", "PGM", "PPM", "PNM", "XBM", "WBMP", "FAX", "PCX", "DCX", "JNG", "PDF", "EPS", "AI"].contains(id)
    }
}

enum FormatCatalog {
    // MARK: Images
    static let images: [FormatDescriptor] = [
        .init(id: "JPEG", ext: "jpg", name: "JPEG", detail: "Universel, photos", kind: .image, group: "Populaires", writer: .native("public.jpeg"), popular: true),
        .init(id: "PNG", ext: "png", name: "PNG", detail: "Sans perte, transparence", kind: .image, group: "Populaires", writer: .native("public.png"), popular: true),
        .init(id: "WEBP", ext: "webp", name: "WebP", detail: "Web moderne, léger", kind: .image, group: "Populaires", writer: .webp, popular: true),
        .init(id: "HEIC", ext: "heic", name: "HEIC", detail: "Format Apple, très efficace", kind: .image, group: "Populaires", writer: .native("public.heic"), popular: true),
        .init(id: "AVIF", ext: "avif", name: "AVIF", detail: "Compression de nouvelle génération", kind: .image, group: "Populaires", writer: .native("public.avif"), popular: true),
        .init(id: "GIF", ext: "gif", name: "GIF", detail: "Animations, 256 couleurs", kind: .image, group: "Populaires", writer: .animated("gif"), popular: true),
        .init(id: "PDF", ext: "pdf", name: "PDF", detail: "Document, une page par image", kind: .image, group: "Populaires", writer: .nativePDF, popular: true),
        .init(id: "TIFF", ext: "tiff", name: "TIFF", detail: "Archivage, impression", kind: .image, group: "Populaires", writer: .native("public.tiff"), popular: true),
        .init(id: "JXL", ext: "jxl", name: "JPEG XL", detail: "Successeur du JPEG", kind: .image, group: "Modernes", writer: .jxl),
        .init(id: "APNG", ext: "png", name: "APNG", detail: "PNG animé", kind: .image, group: "Modernes", writer: .animated("apng")),
        .init(id: "QOI", ext: "qoi", name: "QOI", detail: "Sans perte ultra-rapide", kind: .image, group: "Modernes", writer: .magick("QOI")),
        .init(id: "JP2", ext: "jp2", name: "JPEG 2000", detail: "Cinéma numérique, imagerie médicale", kind: .image, group: "Modernes", writer: .native("public.jpeg-2000")),
        .init(id: "BMP", ext: "bmp", name: "BMP", detail: "Bitmap Windows", kind: .image, group: "Système", writer: .native("com.microsoft.bmp")),
        .init(id: "ICO", ext: "ico", name: "ICO", detail: "Icône Windows (≤ 256 px)", kind: .image, group: "Système", writer: .native("com.microsoft.ico")),
        .init(id: "ICNS", ext: "icns", name: "ICNS", detail: "Icône macOS", kind: .image, group: "Système", writer: .native("com.apple.icns")),
        .init(id: "SVG", ext: "svg", name: "SVG", detail: "Vectoriel (image intégrée)", kind: .image, group: "Système", writer: .magick("SVG")),
        .init(id: "PSD", ext: "psd", name: "PSD", detail: "Photoshop", kind: .image, group: "Pro", writer: .native("com.adobe.photoshop-image")),
        .init(id: "PSB", ext: "psb", name: "PSB", detail: "Photoshop grand format", kind: .image, group: "Pro", writer: .magick("PSB")),
        .init(id: "EPS", ext: "eps", name: "EPS", detail: "PostScript encapsulé", kind: .image, group: "Pro", writer: .postscript("eps2write")),
        .init(id: "AI", ext: "ai", name: "Illustrator (AI)", detail: "Compatible PDF", kind: .image, group: "Pro", writer: .postscript("pdfwrite")),
        .init(id: "EXR", ext: "exr", name: "OpenEXR", detail: "HDR, VFX", kind: .image, group: "Pro", writer: .native("com.ilm.openexr-image")),
        .init(id: "HDR", ext: "hdr", name: "Radiance HDR", detail: "Image haute dynamique", kind: .image, group: "Pro", writer: .magick("HDR")),
        .init(id: "DDS", ext: "dds", name: "DDS", detail: "Textures DirectDraw", kind: .image, group: "Pro", writer: .native("com.microsoft.dds")),
        .init(id: "KTX", ext: "ktx", name: "KTX", detail: "Textures Khronos", kind: .image, group: "Pro", writer: .native("org.khronos.ktx")),
        .init(id: "TGA", ext: "tga", name: "TGA", detail: "Truevision Targa", kind: .image, group: "Pro", writer: .native("com.truevision.tga-image")),
        .init(id: "PTIF", ext: "ptif", name: "Pyramid TIFF", detail: "TIFF multi-résolution", kind: .image, group: "Pro", writer: .magick("PTIF")),
        .init(id: "DPX", ext: "dpx", name: "DPX", detail: "Cinéma numérique", kind: .image, group: "Scientifique & Cinéma", writer: .magick("DPX")),
        .init(id: "CIN", ext: "cin", name: "Cineon", detail: "Scans de film", kind: .image, group: "Scientifique & Cinéma", writer: .magick("CIN")),
        .init(id: "FITS", ext: "fits", name: "FITS", detail: "Astronomie", kind: .image, group: "Scientifique & Cinéma", writer: .magick("FITS")),
        .init(id: "PFM", ext: "pfm", name: "PFM", detail: "Portable Float Map", kind: .image, group: "Scientifique & Cinéma", writer: .magick("PFM")),
        .init(id: "PHM", ext: "phm", name: "PHM", detail: "Portable Half Float", kind: .image, group: "Scientifique & Cinéma", writer: .magick("PHM")),
        .init(id: "VICAR", ext: "vicar", name: "VICAR", detail: "Imagerie planétaire NASA", kind: .image, group: "Scientifique & Cinéma", writer: .magick("VICAR")),
        .init(id: "MAT", ext: "mat", name: "MATLAB", detail: "Matrice MATLAB", kind: .image, group: "Scientifique & Cinéma", writer: .magick("MAT")),
        .init(id: "VIPS", ext: "v", name: "VIPS", detail: "Format libvips", kind: .image, group: "Scientifique & Cinéma", writer: .magick("VIPS")),
        .init(id: "MIFF", ext: "miff", name: "MIFF", detail: "Magick Image File", kind: .image, group: "Scientifique & Cinéma", writer: .magick("MIFF")),
        .init(id: "PBM", ext: "pbm", name: "PBM", detail: "Portable Bitmap", kind: .image, group: "Netpbm & historiques", writer: .magick("PBM")),
        .init(id: "PGM", ext: "pgm", name: "PGM", detail: "Portable Graymap", kind: .image, group: "Netpbm & historiques", writer: .magick("PGM")),
        .init(id: "PPM", ext: "ppm", name: "PPM", detail: "Portable Pixmap", kind: .image, group: "Netpbm & historiques", writer: .magick("PPM")),
        .init(id: "PNM", ext: "pnm", name: "PNM", detail: "Portable Anymap", kind: .image, group: "Netpbm & historiques", writer: .magick("PNM")),
        .init(id: "PAM", ext: "pam", name: "PAM", detail: "Portable Arbitrary Map", kind: .image, group: "Netpbm & historiques", writer: .magick("PAM")),
        .init(id: "SGI", ext: "sgi", name: "SGI", detail: "Silicon Graphics", kind: .image, group: "Netpbm & historiques", writer: .magick("SGI")),
        .init(id: "PCX", ext: "pcx", name: "PCX", detail: "ZSoft Paintbrush", kind: .image, group: "Netpbm & historiques", writer: .magick("PCX")),
        .init(id: "DCX", ext: "dcx", name: "DCX", detail: "PCX multipage", kind: .image, group: "Netpbm & historiques", writer: .magick("DCX")),
        .init(id: "PICT", ext: "pict", name: "PICT", detail: "QuickDraw classique", kind: .image, group: "Netpbm & historiques", writer: .magick("PICT")),
        .init(id: "XBM", ext: "xbm", name: "XBM", detail: "X11 Bitmap", kind: .image, group: "Netpbm & historiques", writer: .magick("XBM")),
        .init(id: "XPM", ext: "xpm", name: "XPM", detail: "X11 Pixmap", kind: .image, group: "Netpbm & historiques", writer: .magick("XPM")),
        .init(id: "MNG", ext: "mng", name: "MNG", detail: "Multiple-image Network Graphics", kind: .image, group: "Netpbm & historiques", writer: .magick("MNG")),
        .init(id: "JNG", ext: "jng", name: "JNG", detail: "JPEG Network Graphics", kind: .image, group: "Netpbm & historiques", writer: .magick("JNG")),
        .init(id: "FF", ext: "ff", name: "farbfeld", detail: "Format suckless", kind: .image, group: "Netpbm & historiques", writer: .magick("FARBFELD")),
        .init(id: "RAS", ext: "ras", name: "Sun Raster", detail: "Sun Microsystems", kind: .image, group: "Netpbm & historiques", writer: .magick("SUN")),
        .init(id: "AVS", ext: "avs", name: "AVS", detail: "Advanced Visual Systems", kind: .image, group: "Netpbm & historiques", writer: .magick("AVS")),
        .init(id: "PALM", ext: "palm", name: "Palm", detail: "Palm Pixmap", kind: .image, group: "Netpbm & historiques", writer: .magick("PALM")),
        .init(id: "PDB", ext: "pdb", name: "Palm DB", detail: "Palm Database ImageViewer", kind: .image, group: "Netpbm & historiques", writer: .magick("PDB")),
        .init(id: "WBMP", ext: "wbmp", name: "WBMP", detail: "Wireless Bitmap", kind: .image, group: "Netpbm & historiques", writer: .magick("WBMP")),
        .init(id: "FAX", ext: "fax", name: "Fax G3", detail: "Groupe 3", kind: .image, group: "Netpbm & historiques", writer: .magick("FAX")),
        .init(id: "SIXEL", ext: "sixel", name: "SIXEL", detail: "Graphismes terminal DEC", kind: .image, group: "Netpbm & historiques", writer: .magick("SIXEL")),
        .init(id: "VIFF", ext: "viff", name: "VIFF", detail: "Khoros Visualization", kind: .image, group: "Netpbm & historiques", writer: .magick("VIFF")),
    ]

    // MARK: Audio
    static let audio: [FormatDescriptor] = [
        .init(id: "MP3", ext: "mp3", name: "MP3", detail: "Universel", kind: .audio, group: "Populaires", writer: .audio(codec: "libmp3lame", muxer: nil, extra: ["-id3v2_version", "3"]), popular: true),
        .init(id: "AAC", ext: "m4a", name: "AAC", detail: "Recommandé, qualité/poids", kind: .audio, group: "Populaires", writer: .audio(codec: "aac_at", muxer: "ipod", extra: []), popular: true),
        .init(id: "M4A", ext: "m4a", name: "M4A", detail: "AAC en conteneur Apple", kind: .audio, group: "Populaires", writer: .audio(codec: "aac_at", muxer: "ipod", extra: []), popular: true),
        .init(id: "ALAC", ext: "m4a", name: "ALAC", detail: "Apple Lossless", kind: .audio, group: "Populaires", writer: .audio(codec: "alac", muxer: "ipod", extra: []), popular: true),
        .init(id: "WAV", ext: "wav", name: "WAV", detail: "Non compressé", kind: .audio, group: "Populaires", writer: .audio(codec: "pcm_s16le", muxer: nil, extra: []), popular: true),
        .init(id: "FLAC", ext: "flac", name: "FLAC", detail: "Sans perte, ouvert", kind: .audio, group: "Populaires", writer: .audio(codec: "flac", muxer: nil, extra: ["-compression_level", "8"]), popular: true),
        .init(id: "AIFF", ext: "aiff", name: "AIFF", detail: "Non compressé Apple", kind: .audio, group: "Populaires", writer: .audio(codec: "pcm_s16be", muxer: nil, extra: []), popular: true),
        .init(id: "OPUS", ext: "opus", name: "Opus", detail: "Codec moderne, voix et musique", kind: .audio, group: "Modernes", writer: .audio(codec: "libopus", muxer: nil, extra: [])),
        .init(id: "OGG", ext: "ogg", name: "Ogg Vorbis", detail: "Ouvert", kind: .audio, group: "Modernes", writer: .audio(codec: "libvorbis", muxer: nil, extra: [])),
        .init(id: "OGA", ext: "oga", name: "OGA", detail: "Ogg audio (FLAC)", kind: .audio, group: "Modernes", writer: .audio(codec: "flac", muxer: "oga", extra: [])),
        .init(id: "M4R", ext: "m4r", name: "M4R", detail: "Sonnerie iPhone (≤ 40 s)", kind: .audio, group: "Apple", writer: .audio(codec: "aac_at", muxer: "ipod", extra: ["-t", "40"])),
        .init(id: "CAF", ext: "caf", name: "CAF", detail: "Core Audio Format", kind: .audio, group: "Apple", writer: .audio(codec: "aac_at", muxer: "caf", extra: [])),
        .init(id: "AIF", ext: "aif", name: "AIF", detail: "AIFF (extension courte)", kind: .audio, group: "Apple", writer: .audio(codec: "pcm_s16be", muxer: "aiff", extra: [])),
        .init(id: "AIFC", ext: "aifc", name: "AIFC", detail: "AIFF compressé", kind: .audio, group: "Apple", writer: .audio(codec: "pcm_s16be", muxer: "aiff", extra: [])),
        .init(id: "AC3", ext: "ac3", name: "AC-3", detail: "Dolby Digital", kind: .audio, group: "Cinéma", writer: .audio(codec: "ac3", muxer: nil, extra: [])),
        .init(id: "EAC3", ext: "eac3", name: "E-AC-3", detail: "Dolby Digital Plus", kind: .audio, group: "Cinéma", writer: .audio(codec: "eac3", muxer: nil, extra: [])),
        .init(id: "DTS", ext: "dts", name: "DTS", detail: "DTS Coherent Acoustics", kind: .audio, group: "Cinéma", writer: .audio(codec: "dca", muxer: "dts", extra: ["-strict", "-2"])),
        .init(id: "MKA", ext: "mka", name: "MKA", detail: "Matroska audio", kind: .audio, group: "Conteneurs", writer: .audio(codec: "libopus", muxer: "matroska", extra: [])),
        .init(id: "WV", ext: "wv", name: "WavPack", detail: "Sans perte hybride", kind: .audio, group: "Sans perte", writer: .audio(codec: "wavpack", muxer: nil, extra: [])),
        .init(id: "TTA", ext: "tta", name: "TTA", detail: "True Audio", kind: .audio, group: "Sans perte", writer: .audio(codec: "tta", muxer: nil, extra: [])),
        .init(id: "W64", ext: "w64", name: "Wave64", detail: "WAV > 4 Go", kind: .audio, group: "Sans perte", writer: .audio(codec: "pcm_s16le", muxer: "w64", extra: [])),
        .init(id: "WMA", ext: "wma", name: "WMA", detail: "Windows Media Audio", kind: .audio, group: "Historiques", writer: .audio(codec: "wmav2", muxer: "asf", extra: [])),
        .init(id: "MP2", ext: "mp2", name: "MP2", detail: "MPEG audio layer 2", kind: .audio, group: "Historiques", writer: .audio(codec: "mp2", muxer: nil, extra: [])),
        .init(id: "AU", ext: "au", name: "AU", detail: "Sun audio", kind: .audio, group: "Historiques", writer: .audio(codec: "pcm_s16be", muxer: "au", extra: [])),
        .init(id: "SND", ext: "snd", name: "SND", detail: "Sun/NeXT audio", kind: .audio, group: "Historiques", writer: .audio(codec: "pcm_s16be", muxer: "au", extra: [])),
        .init(id: "IRCAM", ext: "sf", name: "IRCAM", detail: "Berkeley/IRCAM/CARL", kind: .audio, group: "Historiques", writer: .audio(codec: "pcm_s16le", muxer: "ircam", extra: [])),
        .init(id: "VOC", ext: "voc", name: "VOC", detail: "Creative Voice", kind: .audio, group: "Historiques", writer: .audio(codec: "pcm_u8", muxer: "voc", extra: [])),
    ]

    // MARK: Video
    static let video: [FormatDescriptor] = [
        .init(id: "MP4", ext: "mp4", name: "MP4", detail: "Universel (H.264 / HEVC)", kind: .video, group: "Populaires", writer: .video(container: "mp4", forcedVideo: nil, forcedAudio: nil, extra: ["-movflags", "+faststart"]), popular: true),
        .init(id: "MOV", ext: "mov", name: "MOV", detail: "QuickTime, Apple", kind: .video, group: "Populaires", writer: .video(container: "mov", forcedVideo: nil, forcedAudio: nil, extra: ["-movflags", "+faststart"]), popular: true),
        .init(id: "HEVC", ext: "mp4", name: "HEVC", detail: "H.265 en MP4, moitié moins lourd", kind: .video, group: "Populaires", writer: .video(container: "mp4", forcedVideo: "hevc", forcedAudio: nil, extra: ["-movflags", "+faststart", "-tag:v", "hvc1"]), popular: true),
        .init(id: "WEBM", ext: "webm", name: "WebM", detail: "Web (VP9 + Opus)", kind: .video, group: "Populaires", writer: .video(container: "webm", forcedVideo: "vp9", forcedAudio: "libopus", extra: []), popular: true),
        .init(id: "MKV", ext: "mkv", name: "MKV", detail: "Matroska, tout codec", kind: .video, group: "Populaires", writer: .video(container: "matroska", forcedVideo: nil, forcedAudio: nil, extra: []), popular: true),
        .init(id: "M4V", ext: "m4v", name: "M4V", detail: "Vidéo Apple / iTunes", kind: .video, group: "Apple", writer: .video(container: "ipod", forcedVideo: nil, forcedAudio: "aac_at", extra: ["-movflags", "+faststart"])),
        .init(id: "PRORES", ext: "mov", name: "ProRes", detail: "Montage pro (VideoToolbox)", kind: .video, group: "Apple", writer: .video(container: "mov", forcedVideo: "prores", forcedAudio: "pcm_s16le", extra: [])),
        .init(id: "AVI", ext: "avi", name: "AVI", detail: "Conteneur historique Windows", kind: .video, group: "Conteneurs", writer: .video(container: "avi", forcedVideo: "h264", forcedAudio: "libmp3lame", extra: [])),
        .init(id: "TS", ext: "ts", name: "TS", detail: "MPEG transport stream", kind: .video, group: "Conteneurs", writer: .video(container: "mpegts", forcedVideo: nil, forcedAudio: nil, extra: [])),
        .init(id: "M2TS", ext: "m2ts", name: "M2TS", detail: "Blu-ray / AVCHD", kind: .video, group: "Conteneurs", writer: .video(container: "mpegts", forcedVideo: "h264", forcedAudio: "ac3", extra: ["-mpegts_m2ts_mode", "1"])),
        .init(id: "MTS", ext: "mts", name: "MTS", detail: "Caméscopes AVCHD", kind: .video, group: "Conteneurs", writer: .video(container: "mpegts", forcedVideo: "h264", forcedAudio: "ac3", extra: ["-mpegts_m2ts_mode", "1"])),
        .init(id: "MXF", ext: "mxf", name: "MXF", detail: "Material Exchange (broadcast)", kind: .video, group: "Conteneurs", writer: .video(container: "mxf", forcedVideo: "mpeg2video", forcedAudio: "pcm_s16le", extra: ["-ar", "48000"])),
        .init(id: "OGV", ext: "ogv", name: "OGV", detail: "Ogg Theora", kind: .video, group: "Conteneurs", writer: .video(container: "ogg", forcedVideo: "libtheora", forcedAudio: "libvorbis", extra: [])),
        .init(id: "MPG", ext: "mpg", name: "MPG", detail: "MPEG-2 (DVD)", kind: .video, group: "Historiques", writer: .video(container: "mpeg", forcedVideo: "mpeg2video", forcedAudio: "mp2", extra: [])),
        .init(id: "MPEG", ext: "mpeg", name: "MPEG", detail: "MPEG-2 programme", kind: .video, group: "Historiques", writer: .video(container: "mpeg", forcedVideo: "mpeg2video", forcedAudio: "mp2", extra: [])),
        .init(id: "VOB", ext: "vob", name: "VOB", detail: "DVD vidéo", kind: .video, group: "Historiques", writer: .video(container: "vob", forcedVideo: "mpeg2video", forcedAudio: "ac3", extra: [])),
        .init(id: "M2V", ext: "m2v", name: "M2V", detail: "Flux MPEG-2 brut (sans son)", kind: .video, group: "Historiques", writer: .video(container: "mpeg2video", forcedVideo: "mpeg2video", forcedAudio: "-", extra: [])),
        .init(id: "MJPEG", ext: "avi", name: "Motion JPEG", detail: "Images JPEG successives", kind: .video, group: "Historiques", writer: .video(container: "avi", forcedVideo: "mjpeg", forcedAudio: "pcm_s16le", extra: [])),
        .init(id: "FLV", ext: "flv", name: "FLV", detail: "Flash Video", kind: .video, group: "Historiques", writer: .video(container: "flv", forcedVideo: "h264", forcedAudio: "aac", extra: [])),
        .init(id: "F4V", ext: "f4v", name: "F4V", detail: "Flash MP4", kind: .video, group: "Historiques", writer: .video(container: "f4v", forcedVideo: "h264", forcedAudio: "aac", extra: [])),
        .init(id: "WMV", ext: "wmv", name: "WMV", detail: "Windows Media Video", kind: .video, group: "Historiques", writer: .video(container: "asf", forcedVideo: "wmv2", forcedAudio: "wmav2", extra: [])),
        .init(id: "ASF", ext: "asf", name: "ASF", detail: "Advanced Systems Format", kind: .video, group: "Historiques", writer: .video(container: "asf", forcedVideo: "msmpeg4", forcedAudio: "wmav2", extra: [])),
        .init(id: "3GP", ext: "3gp", name: "3GP", detail: "Mobiles anciens", kind: .video, group: "Historiques", writer: .video(container: "3gp", forcedVideo: "h264", forcedAudio: "aac", extra: [])),
        .init(id: "3G2", ext: "3g2", name: "3G2", detail: "Mobiles CDMA", kind: .video, group: "Historiques", writer: .video(container: "3g2", forcedVideo: "h264", forcedAudio: "aac", extra: [])),
        .init(id: "GIFV", ext: "gif", name: "GIF animé", detail: "Vidéo → GIF (palette optimisée)", kind: .video, group: "Animations", writer: .animated("gif")),
        .init(id: "APNGV", ext: "png", name: "APNG animé", detail: "Vidéo → PNG animé", kind: .video, group: "Animations", writer: .animated("apng")),
        .init(id: "WEBPV", ext: "webp", name: "WebP animé", detail: "Vidéo → WebP animé", kind: .video, group: "Animations", writer: .animated("webp")),
    ]

    // MARK: Documents
    static let office: [FormatDescriptor] = [
        .init(id: "PDFDOC", ext: "pdf", name: "PDF", detail: "Mise en page fixe, à partager", kind: .office, group: "Populaires", writer: .office, popular: true),
        .init(id: "DOCX", ext: "docx", name: "Word (DOCX)", detail: "Microsoft Word moderne", kind: .office, group: "Populaires", writer: .office, popular: true),
        .init(id: "ODT", ext: "odt", name: "ODT", detail: "OpenDocument (LibreOffice)", kind: .office, group: "Populaires", writer: .office, popular: true),
        .init(id: "RTF", ext: "rtf", name: "RTF", detail: "Texte enrichi universel", kind: .office, group: "Populaires", writer: .office, popular: true),
        .init(id: "TXT", ext: "txt", name: "Texte brut", detail: "UTF-8, sans mise en forme", kind: .office, group: "Populaires", writer: .office, popular: true),
        .init(id: "MD", ext: "md", name: "Markdown", detail: "GitHub Flavored Markdown", kind: .office, group: "Populaires", writer: .office, popular: true),
        .init(id: "HTML", ext: "html", name: "HTML", detail: "Page web autonome", kind: .office, group: "Populaires", writer: .office, popular: true),
        .init(id: "EPUB", ext: "epub", name: "EPUB", detail: "Livre numérique (Livres, Kobo…)", kind: .office, group: "Populaires", writer: .office, popular: true),
        .init(id: "DOC", ext: "doc", name: "Word 97–2003", detail: "Ancien format .doc", kind: .office, group: "Traitement de texte", writer: .office),
        .init(id: "WEBARCHIVE", ext: "webarchive", name: "Archive Web", detail: "Safari", kind: .office, group: "Traitement de texte", writer: .office),
        .init(id: "TEX", ext: "tex", name: "LaTeX", detail: "Source LaTeX autonome", kind: .office, group: "Balisage", writer: .office),
        .init(id: "TYP", ext: "typ", name: "Typst", detail: "Composition moderne", kind: .office, group: "Balisage", writer: .office),
        .init(id: "RST", ext: "rst", name: "reStructuredText", detail: "Documentation Python / Sphinx", kind: .office, group: "Balisage", writer: .office),
        .init(id: "ADOC", ext: "adoc", name: "AsciiDoc", detail: "Documentation technique", kind: .office, group: "Balisage", writer: .office),
        .init(id: "ORG", ext: "org", name: "Org", detail: "Org-mode (Emacs)", kind: .office, group: "Balisage", writer: .office),
        .init(id: "WIKI", ext: "wiki", name: "MediaWiki", detail: "Syntaxe Wikipédia", kind: .office, group: "Balisage", writer: .office),
        .init(id: "FB2", ext: "fb2", name: "FictionBook", detail: "Livre numérique FB2", kind: .office, group: "Balisage", writer: .office),
        .init(id: "PPTX", ext: "pptx", name: "PowerPoint (PPTX)", detail: "Une diapositive par titre", kind: .office, group: "Présentations", writer: .office),
        .init(id: "ODP", ext: "odp", name: "ODP", detail: "Présentation OpenDocument · LibreOffice", kind: .office, group: "Présentations", writer: .office),
        .init(id: "XLSX", ext: "xlsx", name: "Excel (XLSX)", detail: "Classeur · LibreOffice", kind: .office, group: "Tableurs", writer: .office),
        .init(id: "ODS", ext: "ods", name: "ODS", detail: "Classeur OpenDocument · LibreOffice", kind: .office, group: "Tableurs", writer: .office),
        .init(id: "CSV", ext: "csv", name: "CSV", detail: "Valeurs séparées · LibreOffice", kind: .office, group: "Tableurs", writer: .office),
    ]

    /// Text outputs offered for PDF sources ("extract the text").
    static let pdfTextOutputs: Set<String> = ["DOCX", "ODT", "RTF", "TXT", "MD", "HTML", "EPUB"]

    static let all: [FormatDescriptor] = images + audio + video + office
    static let byID: [String: FormatDescriptor] = {
        var d: [String: FormatDescriptor] = [:]
        for f in all where d[f.id] == nil { d[f.id] = f }
        return d
    }()
    static func format(_ id: String) -> FormatDescriptor? { byID[id.uppercased()] }

    /// Formats a given input kind can be converted to.
    static func outputs(for kind: MediaKind) -> [FormatDescriptor] {
        switch kind {
        case .image: images
        case .document: images + office.filter { pdfTextOutputs.contains($0.id) }
        case .video: video + audio
        case .audio: audio
        case .office: office
        }
    }

    /// The document flavour of a format chosen for another kind ("pdf" from the CLI or a mapping means PDFDOC for a .docx).
    static func officeEquivalent(of f: FormatDescriptor) -> FormatDescriptor? {
        f.kind == .office ? f : office.first { $0.ext == f.ext }
    }

    /// Best-effort format for an output target, used by CLI / Shortcuts ("jpg", "webp", "MP4"...).
    static func resolve(_ token: String) -> FormatDescriptor? {
        let t = token.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let f = byID[t] { return f }
        let aliases = ["JPG": "JPEG", "TIF": "TIFF", "HEIF": "HEIC", "JPEGXL": "JXL", "OGGVORBIS": "OGG", "MPEG4": "MP4", "AIFF": "AIFF", "QT": "MOV",
                       "WORD": "DOCX", "MARKDOWN": "MD", "TEXT": "TXT", "PLAIN": "TXT", "HTM": "HTML", "LATEX": "TEX", "ASCIIDOC": "ADOC",
                       "EXCEL": "XLSX", "POWERPOINT": "PPTX", "TYPST": "TYP", "MEDIAWIKI": "WIKI"]
        if let a = aliases[t] { return byID[a] }
        return all.first { $0.ext.uppercased() == t }
    }
}

// MARK: - Input detection

enum InputClass: Sendable, Equatable {
    case raster          // ImageIO readable
    case raw             // camera RAW
    case svg
    case postscript      // eps / ai / ps
    case pdf
    case exotic          // needs ImageMagick to read
    case video
    case audio
    case office          // text documents, spreadsheets, presentations, e-books
    case unsupported

    var mediaKind: MediaKind? {
        switch self {
        case .raster, .raw, .svg, .exotic: .image
        case .postscript, .pdf: .document
        case .video: .video
        case .audio: .audio
        case .office: .office
        case .unsupported: nil
        }
    }
}

enum FileDetection {
    static let rawExts: Set<String> = ["arw", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf", "rw2", "pef", "srw", "dng", "3fr", "fff", "iiq", "mef", "mrw", "mdc", "erf", "kdc", "dcr", "rwl", "x3f", "sr2", "srf"]
    static let postscriptExts: Set<String> = ["eps", "ai", "ps", "epsf", "epsi"]
    static let magickReadable: Set<String> = ["qoi", "jxl", "pcx", "dcx", "pict", "pct", "xbm", "xpm", "pbm", "pgm", "ppm", "pnm", "pam", "sgi", "rgb", "dpx", "cin", "fits", "fit", "pfm", "phm", "vicar", "mat", "v", "vips", "miff", "mng", "jng", "ff", "ras", "sun", "avs", "palm", "pdb", "wbmp", "fax", "sixel", "viff", "wpg", "xcf", "ora", "psb", "ptif", "hdr", "cut", "dib", "otb", "pes", "pix", "tim", "jxr", "wdp"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "f4v", "mpg", "mpeg", "m2v", "ts", "m2ts", "mts", "vob", "3gp", "3g2", "ogv", "mxf", "asf", "wtv", "dv", "hevc", "mjpeg", "rm", "rmvb", "divx"]
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "aifc", "caf", "ogg", "oga", "opus", "wma", "ac3", "eac3", "dts", "mka", "wv", "tta", "w64", "au", "snd", "mp2", "voc", "amr", "ape", "m4r", "m4b", "sf", "spx", "mid", "midi"]

    static let officeExts: Set<String> = [
        // word processing
        "doc", "docx", "docm", "dotx", "odt", "ott", "rtf", "rtfd", "txt", "text", "pages", "wpd",
        // web & markup
        "html", "htm", "xhtml", "webarchive", "md", "markdown", "mdown", "mkd", "rst", "org", "tex", "latex", "adoc", "asciidoc",
        "typ", "textile", "wiki", "mediawiki", "dbk", "opml", "ipynb", "djot",
        // e-books
        "epub", "fb2",
        // spreadsheets & presentations
        "xlsx", "xlsm", "xls", "ods", "csv", "tsv", "numbers", "pptx", "ppt", "pps", "ppsx", "odp", "key",
    ]

    static func classify(_ url: URL) -> InputClass {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return .unsupported }
        if officeExts.contains(ext) { return .office }
        if rawExts.contains(ext) { return .raw }
        if postscriptExts.contains(ext) { return .postscript }
        if ext == "pdf" { return .pdf }
        if ext == "svg" || ext == "svgz" { return .svg }
        if videoExts.contains(ext) { return .video }
        if audioExts.contains(ext) { return .audio }
        if ext == "gif" || ext == "png" || ext == "apng" { return .raster }
        if let ut = UTType(filenameExtension: ext) {
            if ut.conforms(to: .movie) || ut.conforms(to: .video) { return .video }
            if ut.conforms(to: .audio) { return .audio }
            if ut.conforms(to: .image), NativeTypes.readable.contains(ut.identifier) { return .raster }
        }
        if magickReadable.contains(ext) { return .exotic }
        if let ut = UTType(filenameExtension: ext), ut.conforms(to: .image) { return .exotic }
        return .unsupported
    }

    /// The catalog format matching an input file (used for "compress = keep the same format").
    static func sameFormat(for url: URL) -> FormatDescriptor? {
        let ext = url.pathExtension.lowercased()
        let map: [String: String] = ["jpg": "JPEG", "jpeg": "JPEG", "jpe": "JPEG", "tif": "TIFF", "tiff": "TIFF", "heif": "HEIC", "heic": "HEIC",
                                     "png": "PNG", "webp": "WEBP", "avif": "AVIF", "gif": "GIF", "pdf": "PDF", "jxl": "JXL", "m4a": "M4A",
                                     "aif": "AIF", "aiff": "AIFF", "mp4": "MP4", "mov": "MOV", "m4v": "M4V", "mkv": "MKV", "webm": "WEBM",
                                     "jp2": "JP2", "j2k": "JP2", "psd": "PSD", "bmp": "BMP", "svg": "SVG", "eps": "EPS", "ai": "AI"]
        if let id = map[ext] { return FormatCatalog.format(id) }
        return FormatCatalog.all.first { $0.ext == ext }
    }
}

enum NativeTypes {
    static let readable: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    static let writable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
}

import ImageIO
