import AVFoundation
import Foundation

final class Playback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var frameCount: AVAudioFramePosition = 0

    func play(_ clip: Clip, volume: Float) throws {
        guard clip.frames > 0, clip.channels == 1 || clip.channels == 2 else {
            throw FoldError(message: "There is no audio to play.")
        }
        let channels = AVAudioChannelCount(clip.channels)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.frames)),
              let data = buffer.floatChannelData else {
            throw FoldError(message: "Couldn't open the audio output.")
        }
        buffer.frameLength = AVAudioFrameCount(clip.frames)
        if clip.channels == 1 {
            for frame in 0..<clip.frames {
                data[0][frame] = Float(clip.samples[frame]) / 32768
            }
        } else {
            for frame in 0..<clip.frames {
                data[0][frame] = Float(clip.samples[frame * 2]) / 32768
                data[1][frame] = Float(clip.samples[frame * 2 + 1]) / 32768
            }
        }
        if !attached {
            engine.attach(player)
            attached = true
        }
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw FoldError(message: "Couldn't start playback.")
        }
        frameCount = AVAudioFramePosition(clip.frames)
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
    }

    func stop() {
        player.stop()
        engine.stop()
        frameCount = 0
    }

    var isPlaying: Bool { player.isPlaying }

    /// Position in the looping buffer, from 0 to 1.
    func progress() -> Double? {
        guard player.isPlaying, frameCount > 0,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        var sample = playerTime.sampleTime % frameCount
        if sample < 0 { sample += frameCount }
        return Double(sample) / Double(frameCount)
    }
}
