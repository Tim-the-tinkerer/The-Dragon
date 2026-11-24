# Dragonfold WAV

A folded export is an ordinary 16-bit PCM WAV. The audio is the scrambled samples. A player reads `fmt ` and `data` and plays them.

The fold note is a chunk named `dcaf`. It is written after `data`, so a program that expects the standard 44-byte header still finds the audio where it expects it. The phrase is not in the chunk.

```
RIFF
  WAVE
  fmt     16-bit PCM, 1 or 2 channels
  data    interleaved little-endian samples
  dcaf    24-byte fold note
```

The note, little-endian:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | Version. This app writes 1. |
| 1 | 1 | Unit. 1 sample, 2 frame, 3 grain. |
| 2 | 1 | Passes, 1 through 7. |
| 3 | 1 | Flags. Bit 0 is 1 when a phrase was used. Bit 1 is 1 when right turns play backward. Bit 2 is 1 when each channel has its own dragon. Other bits are 0. |
| 4 | 4 | Grain, in frames. 1 for sample and frame. |
| 8 | 2 | Channels. Must match `fmt `. |
| 10 | 2 | Bits. 16. |
| 12 | 4 | Sample rate. Must match `fmt `. |
| 16 | 4 | Frame count. Must match `data`. |
| 20 | 4 | CRC-32 of the `data` bytes. |

Restore checks the note against the audio. If the CRC or the sizes do not match, the file still plays and Restore is not offered from the note.

A remainder shorter than one grain is not a segment. It stays at the end of the buffer. The grain and the frame count are enough to find it again.

Sample mode lays one sample of a channel on each segment. On a stereo file each channel walks its own dragon: the left channel uses the phrase, and the right channel uses the same passes with the fold turned over. A note with bit 2 clear is an older sample fold, and both channels share one dragon. Frame mode lays one frame on each segment. Grain mode lays `grain` frames on each segment. Every full segment is the same length.

When bit 1 is set, a grain plays backward if that step of the curve turns right. Frames inside the grain reverse. The channels inside a frame stay in order. A left turn plays forward. The tail is not a segment, so it is left alone.

Turn the note off and this chunk is absent. The WAV is only `fmt ` and `data`.
