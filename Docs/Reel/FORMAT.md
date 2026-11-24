# Dragonreel MP4

A folded export is an H.264 movie in an MPEG-4 file. A player reads the video track and plays the scrambled frames. This version writes frames that fit inside 1920×1080.

The fold note is the movie's description, and the same text is also the QuickTime comment. The phrase is not in either one.

```
DRL1 a=<axis> t=<tile> r=<run> p=<passes> k=<keyed> w=<width> h=<height> n=<frames>
```

| Field | Meaning |
| --- | --- |
| a | 1 scale, 2 fold, 3 both. |
| t | Tile side in pixels. 0 when the fold did not move tiles. |
| r | Frames in a run. 0 when the fold did not move time. |
| p | Passes, 1 through 7. |
| k | 1 if a phrase was used, otherwise 0. |
| w, h | Width and height of the frames that were folded. |
| n | How many frames were folded. |

Restore checks the note against the movie it just decoded. If the width, height, or frame count do not match, the file still plays and Restore is not offered from the note.

Scale lays the same square tiles on the curve for every frame, in row order from the top. A strip that does not fill a tile is not a segment. It stays in place. The tile side and the width and height are enough to find it again.

Fold lays runs of frames on the curve. A run is that many frames, in order. A remainder shorter than one run stays at the end. The run length and the frame count are enough to find it again.

Both applies those two maps. The same phrase builds both of them. The maps commute, so restoring either one first still returns the frames that were loaded.

The sound, when the source had any, is cut into one slice per frame and folded with the picture. Scale cuts that slice into the same number of pieces as there are tiles, when the frame has enough samples, and uses that rearrangement on every frame. A remainder shorter than one piece stays at the end of the slice. When the frame has fewer samples than tiles, each sample is a piece. Fold moves the whole slice with the frame, so the samples inside a run stay in order. A remainder shorter than one frame of samples stays at the end. Both does the two. The slice length and the sample count are enough to find the sound again. The phrase is not stored.

The exported sound is AAC. Restore puts the loaded samples back. A movie opened from that file carries the codec's own change, the same way H.264 does for the picture. More than two channels are kept as the first two. A sample rate AAC cannot store is read at 48 kHz.

Turn the note off and the description is empty of this line. The MP4 is only the movie.

H.264 does not keep every pixel. Dragonreel restores the order of the frames it decoded. The codec's own change is still there. The self-test checks the order on the frames before they are encoded, where the rearrangement is exact.
