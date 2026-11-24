import AudioToolbox
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

enum MovieTime {
    /// One frame, as a rational that the writer and the reader can share.
    static func step(fps: Double) -> CMTime {
        let rate = fps.isFinite && fps >= 1 ? fps : 30
        if abs(rate - 24) < 0.02 { return CMTime(value: 1_000, timescale: 24_000) }
        if abs(rate - 25) < 0.02 { return CMTime(value: 1_000, timescale: 25_000) }
        if abs(rate - 30) < 0.02 { return CMTime(value: 1_000, timescale: 30_000) }
        if abs(rate - 50) < 0.02 { return CMTime(value: 1_000, timescale: 50_000) }
        if abs(rate - 60) < 0.02 { return CMTime(value: 1_000, timescale: 60_000) }
        if abs(rate - 23.976) < 0.02 { return CMTime(value: 1_001, timescale: 24_000) }
        if abs(rate - 29.97) < 0.03 { return CMTime(value: 1_001, timescale: 30_000) }
        if abs(rate - 59.94) < 0.03 { return CMTime(value: 1_001, timescale: 60_000) }
        let scale: CMTimeScale = 60_000
        let value = max(1, CMTimeValue((60_000.0 / rate).rounded()))
        return CMTime(value: value, timescale: scale)
    }

    static func fps(of step: CMTime) -> Double {
        guard step.value > 0 else { return 30 }
        return Double(step.timescale) / Double(step.value)
    }
}

/// Blocks until an async load finishes. Pumps the current run loop so a call
/// on the main thread does not deadlock against AVFoundation.
enum Wait {
    static func value<T>(seconds: TimeInterval = 60, _ work: @escaping () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let ready = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await work()) }
            catch { box.result = .failure(error) }
            ready.signal()
        }
        let deadline = Date().addingTimeInterval(seconds)
        while ready.wait(timeout: .now()) == .timedOut {
            if Date() > deadline {
                throw FoldError(message: "The movie took too long to open.")
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        guard let result = box.result else {
            throw FoldError(message: "The movie could not be read.")
        }
        return try result.get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

enum MovieIO {
    static func load(_ url: URL, span: ReelSpan = .preview, progress: (String) -> Void) throws -> Reel {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            throw FoldError(message: "Choose a movie file.")
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try Wait.value { try await asset.loadTracks(withMediaType: .video) }
        guard let track = tracks.first else {
            throw FoldError(message: "That file has no video.")
        }
        let natural = try Wait.value { try await track.load(.naturalSize) }
        let preferred = try Wait.value { try await track.load(.preferredTransform) }
        let nominal = try Wait.value { try await track.load(.nominalFrameRate) }
        let duration = try Wait.value { try await asset.load(.duration) }
        let transformed = CGRect(origin: .zero, size: natural).applying(preferred)
        let displayW = max(1, Int(abs(transformed.width).rounded()))
        let displayH = max(1, Int(abs(transformed.height).rounded()))
        let fitted = FrameFit.size(width: displayW, height: displayH)
        guard fitted.width >= 2, fitted.height >= 2 else {
            throw FoldError(message: "That movie has no picture.")
        }
        var fps = Double(nominal)
        if !fps.isFinite || fps < 1 { fps = 30 }
        if fps > 240 { fps = 240 }
        let step = MovieTime.step(fps: fps)
        fps = MovieTime.fps(of: step)

        let facts = try audioFacts(asset)
        var frameHint: Int?
        var frameBudget: Int64?
        if span == .full {
            guard duration.seconds.isFinite, duration.seconds > 0 else {
                throw FoldError(message: "That movie's length could not be measured, so the full movie was not loaded.")
            }
            guard let job = StorageBudget.job(
                width: fitted.width,
                height: fitted.height,
                fps: fps,
                seconds: duration.seconds,
                sampleRate: facts.rate,
                channels: facts.channels,
                hasSound: facts.present
            ) else {
                throw FoldError(message: "That movie's length could not be measured, so the full movie was not loaded.")
            }
            if let reason = StorageBudget.refusal(job, free: StorageBudget.freeBytes()) {
                throw FoldError(message: reason)
            }
            frameHint = job.frames
            frameBudget = job.pictureBytes
        }
        let limit = ReadLimit.make(span, frameBudget: frameBudget)
        progress("Reading \(url.lastPathComponent)…")
        let reel = try read(
            asset: asset,
            track: track,
            preferred: preferred,
            natural: natural,
            render: CGSize(width: fitted.width, height: fitted.height),
            fps: fps,
            step: step,
            name: url.lastPathComponent,
            reduced: fitted.fitted,
            assetSeconds: duration.seconds,
            limit: limit,
            frameHint: frameHint,
            progress: progress
        )
        if let note = try? noteText(in: asset), let mark = ReelMark.parse(note) {
            if mark.width == reel.width, mark.height == reel.height, mark.frames == reel.count {
                reel.mark = mark
            } else if reel.clipped == nil {
                reel.clipped = "The fold note does not match this copy."
            } else {
                reel.clipped = (reel.clipped ?? "") + " The fold note does not match this copy."
            }
        }
        do {
            let whole = span == .full && reel.clipped == nil
            reel.sound = try readSound(
                asset: asset,
                seconds: whole ? duration.seconds : reel.duration,
                wholeFile: whole,
                progress: progress
            )
        } catch {
            let note = "The sound could not be read."
            reel.clipped = reel.clipped.map { $0 + " " + note } ?? note
        }
        guard reel.count > 0 else {
            throw FoldError(message: "That movie has no frames.")
        }
        return reel
    }

    static func noteText(in url: URL) throws -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        return try noteText(in: asset)
    }

    static func write(
        reel: Reel,
        note: String?,
        to url: URL,
        replacing: URL?,
        progress: ((String) -> Void)? = nil
    ) throws -> String? {
        if url.pathExtension.lowercased() != "mp4" {
            throw FoldError(message: "Export writes a .mp4 file.")
        }
        if let replacing, sameFile(url, replacing) {
            throw FoldError(message: "Choose a new file. The original stays where it is.")
        }
        if reel.count == 0 {
            throw FoldError(message: "That reel has no frames.")
        }
        do {
            try encode(reel: reel, includeSound: reel.sound != nil, note: note, to: url, progress: progress)
            return nil
        } catch {
            guard reel.sound != nil else { throw error }
            let reason = error.localizedDescription
            try? FileManager.default.removeItem(at: url)
            try encode(reel: reel, includeSound: false, note: note, to: url, progress: progress)
            return "The picture was written. The sound was left out. \(reason)"
        }
    }

    static func preview(_ reel: Reel, progress: ((String) -> Void)? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dragonreel-preview-\(UUID().uuidString).mp4")
        _ = try write(reel: reel, note: nil, to: url, replacing: nil, progress: progress)
        return url
    }

    // MARK: - Read

    private static func read(
        asset: AVAsset,
        track: AVAssetTrack,
        preferred: CGAffineTransform,
        natural: CGSize,
        render: CGSize,
        fps: Double,
        step: CMTime,
        name: String,
        reduced: Bool,
        assetSeconds: Double,
        limit: ReadLimit,
        frameHint: Int?,
        progress: (String) -> Void
    ) throws -> Reel {
        let composed = try? readComposed(
            asset: asset,
            track: track,
            preferred: preferred,
            natural: natural,
            render: render,
            fps: fps,
            name: name,
            reduced: reduced,
            assetSeconds: assetSeconds,
            limit: limit,
            frameHint: frameHint,
            progress: progress
        )
        if let composed, composed.count > 0 { return composed }
        return try readPlain(
            asset: asset,
            track: track,
            render: render,
            fps: fps,
            step: step,
            name: name,
            reduced: reduced,
            assetSeconds: assetSeconds,
            limit: limit,
            frameHint: frameHint,
            progress: progress
        )
    }

    private static func readComposed(
        asset: AVAsset,
        track: AVAssetTrack,
        preferred: CGAffineTransform,
        natural: CGSize,
        render: CGSize,
        fps: Double,
        name: String,
        reduced: Bool,
        assetSeconds: Double,
        limit: ReadLimit,
        frameHint: Int?,
        progress: (String) -> Void
    ) throws -> Reel {
        let composition = AVMutableVideoComposition()
        composition.renderSize = render
        composition.frameDuration = MovieTime.step(fps: fps)
        composition.sourceTrackIDForFrameTiming = track.trackID
        let instruction = AVMutableVideoCompositionInstruction()
        let covered = limit.maxSeconds.map { max(assetSeconds, $0) + 5 } ?? max(assetSeconds, 0.01)
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: covered, preferredTimescale: 600))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(displayTransform(preferred: preferred, natural: natural, render: render), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        let reader = try AVAssetReader(asset: asset)
        if let maxSeconds = limit.maxSeconds {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        }
        guard reader.canAdd(output) else {
            throw FoldError(message: "Could not read that movie.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw FoldError(message: reader.error?.localizedDescription ?? "Could not read that movie.")
        }
        return try takeFrames(
            from: output,
            reader: reader,
            width: Int(render.width),
            height: Int(render.height),
            fps: fps,
            name: name,
            reduced: reduced,
            assetSeconds: assetSeconds,
            limit: limit,
            frameHint: frameHint,
            progress: progress
        )
    }

    private static func readPlain(
        asset: AVAsset,
        track: AVAssetTrack,
        render: CGSize,
        fps: Double,
        step: CMTime,
        name: String,
        reduced: Bool,
        assetSeconds: Double,
        limit: ReadLimit,
        frameHint: Int?,
        progress: (String) -> Void
    ) throws -> Reel {
        let settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        let reader = try AVAssetReader(asset: asset)
        if let maxSeconds = limit.maxSeconds {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        }
        guard reader.canAdd(output) else {
            throw FoldError(message: "Could not read that movie.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw FoldError(message: reader.error?.localizedDescription ?? "Could not read that movie.")
        }
        return try takeFrames(
            from: output,
            reader: reader,
            width: Int(render.width),
            height: Int(render.height),
            fps: fps,
            name: name,
            reduced: reduced,
            assetSeconds: assetSeconds,
            limit: limit,
            frameHint: frameHint,
            progress: progress
        )
    }

    private static func takeFrames(
        from output: AVAssetReaderOutput,
        reader: AVAssetReader,
        width: Int,
        height: Int,
        fps: Double,
        name: String,
        reduced: Bool,
        assetSeconds: Double,
        limit: ReadLimit,
        frameHint: Int?,
        progress: (String) -> Void
    ) throws -> Reel {
        let reel = try Reel.receiving(
            width: width,
            height: height,
            frames: limit.maxFrames ?? frameHint,
            fps: fps,
            name: name,
            reduced: reduced,
            clipped: nil
        )
        var stoppedForFrames = false
        var stoppedForCache = false
        var stoppedForTime = false
        var stoppedForBudget = false
        while let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if let maxSeconds = limit.maxSeconds, pts.isNumeric, pts.seconds >= maxSeconds {
                stoppedForTime = true
                break
            }
            if let maxFrames = limit.maxFrames, reel.count >= maxFrames {
                stoppedForFrames = true
                break
            }
            if let maxCache = limit.maxCacheBytes, reel.count > 0,
               Int64(reel.storedBytes) + Int64(reel.byteCount) > Int64(maxCache) {
                stoppedForCache = true
                break
            }
            if let budget = limit.frameBudget, reel.byteCount > 0 {
                let allowed = budget + Int64(reel.byteCount) * 2
                let next = Int64(reel.count + 1) * Int64(reel.byteCount)
                if next > allowed {
                    stoppedForBudget = true
                    break
                }
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pixels = try FramePixels.rgba(from: buffer, width: width, height: height)
            try reel.append(pixels)
            if reel.count % 12 == 0 {
                progress("Reading frame \(reel.count)…")
            }
        }
        if reader.status == .failed {
            throw FoldError(message: reader.error?.localizedDescription ?? "Could not read that movie.")
        }
        reader.cancelReading()
        let pastCap = limit.maxSeconds.map { assetSeconds > $0 + 0.08 } ?? false
        reel.clipped = clipSentence(
            assetSeconds: assetSeconds,
            loaded: reel.duration,
            fitted: reduced,
            frames: stoppedForFrames,
            cache: stoppedForCache,
            budget: stoppedForBudget,
            time: (stoppedForTime || pastCap) && assetSeconds > reel.duration + 0.08
        )
        return reel
    }

    private static func clipSentence(
        assetSeconds: Double,
        loaded: Double,
        fitted: Bool,
        frames: Bool,
        cache: Bool,
        budget: Bool,
        time: Bool
    ) -> String? {
        var parts: [String] = []
        if fitted { parts.append("Fitted inside 1920×1080.") }
        if cache {
            parts.append("The frame cache is full, so the load stopped at \(AppInfo.seconds(loaded)).")
        } else if budget {
            parts.append("The movie ran past the space set aside for it, so the load stopped at \(AppInfo.seconds(loaded)).")
        } else if frames {
            parts.append("The first \(AppInfo.maxFrames) frames were loaded.")
        } else if time, assetSeconds > loaded + 0.08 {
            parts.append("Loaded the first \(AppInfo.seconds(loaded)).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func displayTransform(preferred: CGAffineTransform, natural: CGSize, render: CGSize) -> CGAffineTransform {
        let transformed = CGRect(origin: .zero, size: natural).applying(preferred)
        let displayW = abs(transformed.width)
        let displayH = abs(transformed.height)
        guard displayW > 1, displayH > 1 else { return .identity }
        var transform = preferred.concatenating(
            CGAffineTransform(translationX: -transformed.origin.x, y: -transformed.origin.y)
        )
        let sx = render.width / displayW
        let sy = render.height / displayH
        transform = transform.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        return transform
    }

    // MARK: - Write

    private static func encode(
        reel: Reel,
        includeSound: Bool,
        note: String?,
        to url: URL,
        progress: ((String) -> Void)?
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = max(2_000_000, reel.width * reel.height * 6)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: reel.width,
            AVVideoHeightKey: reel.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: reel.fps,
            ],
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: reel.width,
            kCVPixelBufferHeightKey as String: reel.height,
        ])
        guard writer.canAdd(video) else {
            throw FoldError(message: "Could not write that movie.")
        }
        writer.add(video)
        let audioInput = try audioInput(for: writer, sound: includeSound ? reel.sound : nil)
        if let note {
            writer.metadata = noteItems(note)
        }
        guard writer.startWriting() else {
            throw FoldError(message: writer.error?.localizedDescription ?? "Could not write that movie.")
        }
        let step = MovieTime.step(fps: reel.fps)
        writer.startSession(atSourceTime: .zero)
        if includeSound, let sound = reel.sound, sound.frames > 0, let audioInput {
            let format = try pcmFormat(sound)
            try writeTogether(
                reel: reel, writer: writer, video: video, adaptor: adaptor,
                audio: audioInput, sound: sound, format: format, step: step, progress: progress
            )
        } else {
            try writePicture(
                reel: reel, writer: writer, video: video, adaptor: adaptor, step: step, progress: progress
            )
        }
        guard writer.status == .completed else {
            throw FoldError(message: writer.error?.localizedDescription ?? "Could not write that movie.")
        }
    }

    /// The writer stops taking frames once the picture is ahead of the sound.
    /// Polling never resumes it. Asking on a queue lets the writer pull whichever
    /// input has room, which is what keeps a movie longer than a second audible.
    private static func writeTogether(
        reel: Reel,
        writer: AVAssetWriter,
        video: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audio: AVAssetWriterInput,
        sound: Soundtrack,
        format: CMAudioFormatDescription,
        step: CMTime,
        progress: ((String) -> Void)?
    ) throws {
        let queue = DispatchQueue(label: "com.tim.dragonreel.writer")
        let gate = DispatchGroup()
        let pace = WriterPace()
        var frameIndex = 0
        var audioCursor = 0
        var videoClosed = false
        var audioClosed = false

        func closeVideo() {
            if videoClosed { return }
            videoClosed = true
            gate.leave()
        }
        func closeAudio() {
            if audioClosed { return }
            audioClosed = true
            gate.leave()
        }
        func fail(_ message: String) {
            pace.fail(message)
            writer.cancelWriting()
            closeVideo()
            closeAudio()
        }

        gate.enter()
        gate.enter()
        video.requestMediaDataWhenReady(on: queue) {
            if videoClosed { return }
            guard writer.status == .writing else {
                closeVideo()
                return
            }
            var pixels = [UInt8]()
            while video.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    closeVideo()
                    return
                }
                if frameIndex >= reel.count {
                    video.markAsFinished()
                    closeVideo()
                    return
                }
                let start = CMTime(value: step.value * CMTimeValue(frameIndex), timescale: step.timescale)
                if frameIndex % 8 == 0 {
                    progress?("Writing frame \(frameIndex + 1) of \(reel.count)…")
                }
                do {
                    try reel.read(into: &pixels, at: frameIndex)
                } catch {
                    fail(error.localizedDescription)
                    return
                }
                guard let buffer = FramePixels.buffer(from: pixels, width: reel.width, height: reel.height) else {
                    fail("Could not write that movie.")
                    return
                }
                if !adaptor.append(buffer, withPresentationTime: start) {
                    fail(writer.error?.localizedDescription ?? "Could not write that movie.")
                    return
                }
                frameIndex += 1
                pace.touch(frame: frameIndex, samples: audioCursor)
            }
        }
        audio.requestMediaDataWhenReady(on: queue) {
            if audioClosed { return }
            guard writer.status == .writing else {
                closeAudio()
                return
            }
            while audio.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    closeAudio()
                    return
                }
                if audioCursor >= sound.frames {
                    audio.markAsFinished()
                    closeAudio()
                    return
                }
                do {
                    let wrote = try writeSoundChunk(
                        audio, sound: sound, format: format,
                        through: sound.frames, cursor: &audioCursor, writer: writer
                    )
                    if !wrote { return }
                } catch {
                    fail(error.localizedDescription)
                    return
                }
                pace.touch(frame: frameIndex, samples: audioCursor)
            }
        }

        try waitForTracks(gate, pace: pace, writer: writer)
        if let message = pace.failure() {
            throw FoldError(message: message)
        }
        guard writer.status == .writing else {
            throw FoldError(message: writer.error?.localizedDescription ?? "Could not write that movie.")
        }
        var end = CMTime(value: step.value * CMTimeValue(reel.count), timescale: step.timescale)
        if sound.sampleRate > 0 {
            let audioEnd = CMTime(value: CMTimeValue(sound.frames), timescale: CMTimeScale(sound.sampleRate))
            if CMTimeCompare(audioEnd, end) > 0 { end = audioEnd }
        }
        writer.endSession(atSourceTime: end)
        try finishWriting(writer)
    }

    private static func writePicture(
        reel: Reel,
        writer: AVAssetWriter,
        video: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        step: CMTime,
        progress: ((String) -> Void)?
    ) throws {
        var pixels = [UInt8]()
        var frameIndex = 0
        var idleSince = Date()
        while frameIndex < reel.count {
            if Date().timeIntervalSince(idleSince) > 60 {
                throw FoldError(message: "The movie writer stalled. frame \(frameIndex) of \(reel.count).")
            }
            if video.isReadyForMoreMediaData {
                let start = CMTime(value: step.value * CMTimeValue(frameIndex), timescale: step.timescale)
                if frameIndex % 8 == 0 {
                    progress?("Writing frame \(frameIndex + 1) of \(reel.count)…")
                }
                try reel.read(into: &pixels, at: frameIndex)
                guard let buffer = FramePixels.buffer(from: pixels, width: reel.width, height: reel.height) else {
                    throw FoldError(message: "Could not write that movie.")
                }
                if !adaptor.append(buffer, withPresentationTime: start) {
                    throw FoldError(message: writer.error?.localizedDescription ?? "Could not write that movie.")
                }
                frameIndex += 1
                idleSince = Date()
            } else {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
        }
        let end = CMTime(value: step.value * CMTimeValue(reel.count), timescale: step.timescale)
        writer.endSession(atSourceTime: end)
        video.markAsFinished()
        try finishWriting(writer)
    }

    private static func waitForTracks(_ group: DispatchGroup, pace: WriterPace, writer: AVAssetWriter) throws {
        while group.wait(timeout: .now()) == .timedOut {
            if pace.idle() > 60 || writer.status == .failed || writer.status == .cancelled {
                let place = pace.place()
                if writer.status == .writing { writer.cancelWriting() }
                _ = group.wait(timeout: .now() + 2)
                if let message = pace.failure() {
                    throw FoldError(message: message)
                }
                if writer.status == .failed, let message = writer.error?.localizedDescription {
                    throw FoldError(message: message)
                }
                throw FoldError(message: "The movie writer stalled. frame \(place.frame), sound \(place.samples).")
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private static func finishWriting(_ writer: AVAssetWriter) throws {
        let ready = DispatchSemaphore(value: 0)
        writer.finishWriting { ready.signal() }
        let finishBy = Date().addingTimeInterval(180)
        while ready.wait(timeout: .now()) == .timedOut {
            if Date() > finishBy {
                writer.cancelWriting()
                throw FoldError(message: "The movie writer stalled.")
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        guard writer.status == .completed else {
            throw FoldError(message: writer.error?.localizedDescription ?? "Could not write that movie.")
        }
    }

    private final class WriterPace: @unchecked Sendable {
        private let lock = NSLock()
        private var at = Date()
        private var frame = 0
        private var samples = 0
        private var message: String?

        func touch(frame: Int, samples: Int) {
            lock.lock()
            at = Date()
            self.frame = frame
            self.samples = samples
            lock.unlock()
        }

        func idle() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(at)
        }

        func place() -> (frame: Int, samples: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (frame, samples)
        }

        func fail(_ text: String) {
            lock.lock()
            if message == nil { message = text }
            lock.unlock()
        }

        func failure() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return message
        }
    }

    private static let aacRates: Set<Int> = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000,
    ]

    private struct AudioFacts {
        var rate: Int
        var channels: Int
        var present: Bool
    }

    /// Rate and channel count, without reading the samples. A missing description
    /// is treated as stereo 48 kHz, which is what the reader will store.
    private static func audioFacts(_ asset: AVAsset) throws -> AudioFacts {
        let tracks = try Wait.value { try await asset.loadTracks(withMediaType: .audio) }
        guard let track = tracks.first else {
            return AudioFacts(rate: 48_000, channels: 2, present: false)
        }
        var rate = 48_000
        var sourceChannels = 2
        if let first = try Wait.value(seconds: 30, { try await track.load(.formatDescriptions) }).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
            if basic.mSampleRate > 0 {
                let rounded = Int(basic.mSampleRate.rounded())
                rate = aacRates.contains(rounded) ? rounded : 48_000
            }
            if basic.mChannelsPerFrame > 0 { sourceChannels = Int(basic.mChannelsPerFrame) }
        }
        return AudioFacts(rate: rate, channels: min(2, max(1, sourceChannels)), present: true)
    }

    private static func readSound(
        asset: AVAsset,
        seconds: Double,
        wholeFile: Bool,
        progress: (String) -> Void
    ) throws -> Soundtrack? {
        let facts = try audioFacts(asset)
        guard facts.present else { return nil }
        progress("Reading sound…")
        let rate = facts.rate
        let channels = facts.channels
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ]
        let tracks = try Wait.value { try await asset.loadTracks(withMediaType: .audio) }
        guard let track = tracks.first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        let span = max(seconds, 0.01)
        if !wholeFile {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: span, preferredTimescale: 600))
        }
        guard reader.canAdd(output) else {
            throw FoldError(message: "Could not read the sound.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw FoldError(message: reader.error?.localizedDescription ?? "Could not read the sound.")
        }
        let cap = Int((Double(rate) * span + Double(rate)).rounded(.up))
        let byteGuess = Int64(cap) * Int64(channels) * 2
        let spill = byteGuess > Int64(AppInfo.memorySoundBytes)
        var samples: [Int16] = []
        let store = spill ? try SoundStore(channels: channels) : nil
        if !spill { samples.reserveCapacity(min(cap, rate) * channels) }
        var frames = 0
        while frames < cap, let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            let taken = takeSound(sample, channels: channels, cap: cap, frames: frames)
            guard !taken.isEmpty else { continue }
            if let store {
                try store.append(taken)
            } else {
                samples.append(contentsOf: taken)
            }
            frames += taken.count / channels
        }
        if reader.status == .failed {
            throw FoldError(message: reader.error?.localizedDescription ?? "Could not read the sound.")
        }
        reader.cancelReading()
        guard frames > 0 else { return nil }
        if let store {
            return Soundtrack(sampleRate: rate, channels: channels, file: store)
        }
        return Soundtrack(sampleRate: rate, channels: channels, samples: samples)
    }

    private static func takeSound(
        _ sample: CMSampleBuffer,
        channels: Int,
        cap: Int,
        frames: Int
    ) -> [Int16] {
        let available = Int(CMSampleBufferGetNumSamples(sample))
        guard available > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let take = min(available, cap - frames)
        guard take > 0 else { return [] }
        let byteCount = available * channels * MemoryLayout<Float>.size
        guard CMBlockBufferGetDataLength(block) >= byteCount else { return [] }
        var pcm = [Float](repeating: 0, count: available * channels)
        let status = pcm.withUnsafeMutableBytes { raw -> OSStatus in
            guard let dest = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: dest)
        }
        guard status == kCMBlockBufferNoErr else { return [] }
        var samples: [Int16] = []
        samples.reserveCapacity(take * channels)
        for index in 0..<take {
            for channel in 0..<channels {
                samples.append(quantize(pcm[index * channels + channel]))
            }
        }
        return samples
    }

    private static func quantize(_ sample: Float) -> Int16 {
        let clamped = min(1, max(-1, sample))
        return Int16((clamped * 32_767).rounded())
    }

    private static func audioInput(for writer: AVAssetWriter, sound: Soundtrack?) throws -> AVAssetWriterInput? {
        guard let sound, sound.frames > 0, sound.sampleRate > 0 else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sound.sampleRate,
            AVNumberOfChannelsKey: sound.channels,
            AVEncoderBitRateKey: sound.channels == 1 ? 96_000 : 160_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw FoldError(message: "Could not write the sound.")
        }
        writer.add(input)
        return input
    }

    /// One slice of PCM. Returns false when the input cannot take it yet.
    private static func writeSoundChunk(
        _ input: AVAssetWriterInput,
        sound: Soundtrack,
        format: CMAudioFormatDescription,
        through end: Int,
        cursor: inout Int,
        writer: AVAssetWriter
    ) throws -> Bool {
        let limit = min(sound.frames, max(end, 0))
        guard cursor < limit, input.isReadyForMoreMediaData else { return false }
        let channels = sound.channels
        let count = min(8_192, limit - cursor)
        let slice = try sound.readSamples(frame: cursor, count: count)
        let when = CMTime(value: CMTimeValue(cursor), timescale: CMTimeScale(sound.sampleRate))
        guard let buffer = sampleBuffer(
            samples: slice,
            frames: count,
            channels: channels,
            rate: sound.sampleRate,
            when: when,
            format: format
        ) else {
            throw FoldError(message: "Could not write the sound.")
        }
        if !input.append(buffer) {
            throw FoldError(message: writer.error?.localizedDescription ?? "Could not write the sound.")
        }
        cursor += count
        return true
    }

    private static func pcmFormat(_ sound: Soundtrack) throws -> CMAudioFormatDescription {
        var basic = AudioStreamBasicDescription(
            mSampleRate: Float64(sound.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(sound.channels * MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(sound.channels * MemoryLayout<Int16>.size),
            mChannelsPerFrame: UInt32(sound.channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &basic,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw FoldError(message: "Could not write the sound.")
        }
        return format
    }

    private static func sampleBuffer(
        samples: [Int16],
        frames: Int,
        channels: Int,
        rate: Int,
        when: CMTime,
        format: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        let byteCount = frames * channels * MemoryLayout<Int16>.size
        guard byteCount > 0, samples.count * MemoryLayout<Int16>.size >= byteCount else { return nil }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = samples.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: when,
            decodeTimeStamp: .invalid
        )
        var sampleSize = channels * MemoryLayout<Int16>.size
        var buffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &buffer
        )
        guard status == noErr else { return nil }
        return buffer
    }

    private static func noteItems(_ note: String) -> [AVMetadataItem] {
        let description = AVMutableMetadataItem()
        description.identifier = .commonIdentifierDescription
        description.keySpace = .common
        description.key = AVMetadataKey.commonKeyDescription as NSString
        description.value = note as NSString
        description.dataType = kCMMetadataBaseDataType_UTF8 as String
        let comment = AVMutableMetadataItem()
        comment.identifier = .quickTimeMetadataComment
        comment.value = note as NSString
        comment.dataType = kCMMetadataBaseDataType_UTF8 as String
        return [description, comment]
    }

    private static func noteText(in asset: AVAsset) throws -> String? {
        let groups = try Wait.value { () -> [[AVMetadataItem]] in
            let common = try await asset.load(.commonMetadata)
            let all = try await asset.load(.metadata)
            return [common, all]
        }
        for items in groups {
            for item in items {
                if let text = try metadataString(item), let line = dragonLine(in: text) {
                    return line
                }
            }
        }
        return nil
    }

    private static func metadataString(_ item: AVMetadataItem) throws -> String? {
        if let text = try Wait.value({ try await item.load(.stringValue) }) {
            return text
        }
        if let data = try Wait.value({ try await item.load(.dataValue) }) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private static func dragonLine(in text: String) -> String? {
        guard let range = text.range(of: "DRL1 ") else { return nil }
        let tail = text[range.lowerBound...]
        let line = tail.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(tail)
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func sameFile(_ left: URL, _ right: URL) -> Bool {
        left.standardizedFileURL.resolvingSymlinksInPath().path
            == right.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum FramePixels {
    static func rgba(from buffer: CVPixelBuffer, width: Int, height: Int) throws -> [UInt8] {
        if let exact = copyBGRA(buffer, width: width, height: height) {
            return exact
        }
        return try scale(buffer, width: width, height: height)
    }

    static func buffer(from rgba: [UInt8], width: Int, height: Int) -> CVPixelBuffer? {
        guard rgba.count == width * height * 4 else { return nil }
        var buffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        rgba.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let dst = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let s = src.advanced(by: y * width * 4)
                let d = dst.advanced(by: y * rowBytes)
                for x in 0..<width {
                    d[x * 4] = s[x * 4 + 2]
                    d[x * 4 + 1] = s[x * 4 + 1]
                    d[x * 4 + 2] = s[x * 4]
                    d[x * 4 + 3] = s[x * 4 + 3]
                }
            }
        }
        return buffer
    }

    private static func copyBGRA(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { raw in
            guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let src = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let s = src.advanced(by: y * rowBytes)
                let d = dst.advanced(by: y * width * 4)
                for x in 0..<width {
                    d[x * 4] = s[x * 4 + 2]
                    d[x * 4 + 1] = s[x * 4 + 1]
                    d[x * 4 + 2] = s[x * 4]
                    d[x * 4 + 3] = 255
                }
            }
        }
        return out
    }

    private static func scale(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let srcW = CVPixelBufferGetWidth(buffer)
        let srcH = CVPixelBufferGetHeight(buffer)
        guard srcW > 0, srcH > 0, let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw FoldError(message: "Could not read a frame.")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let source = CGContext(
                data: base,
                width: srcW,
                height: srcH,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: space,
                bitmapInfo: info
              ),
              let image = source.makeImage() else {
            throw FoldError(message: "Could not read a frame.")
        }
        var out = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw FoldError(message: "Could not read a frame.") }
        return out
    }
}
