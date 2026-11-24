# Changelog

## 1.2.0

- Preview still keeps the first 20 seconds or 600 frames.
- Full movie keeps the whole file when the temporary space for the loaded frames, the folded frames, and the sound is free.
- A long soundtrack is stored in a temporary file instead of two copies in memory.
- A movie larger than 4 GB can be opened. Free temporary space decides whether the full movie fits.

## 1.1.1

- A movie longer than about a second kept its picture and dropped its sound. The sound is now written with the frames.

## 1.1.0

- The sound in each frame is folded with the picture.
- Scale cuts that sound into the same pieces as the tiles. A larger tile keeps a longer piece together.
- Fold moves each frame's sound with the frame. A longer run keeps the sound inside it.
- The exported movie writes that sound as AAC.

## 1.0.0

- Fold a movie on the Heighway dragon and export an MP4 that still plays.
- Scale keeps one tile rearrangement on every frame, so motion stays continuous.
- Fold moves runs of frames. A longer run keeps the motion inside it.
- Both moves tiles and runs together.
- This version fits each frame inside 1920×1080.
- A description note records the fold. The phrase is not stored.
- Restore puts the tiles and the runs back. The original file is left alone.
