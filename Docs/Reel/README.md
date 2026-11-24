# Dragonreel

A Mac window that scrambles a movie with the Heighway dragon, then writes an MP4 you can play.

The curve is the same transposition as Dragonfold and Dragonscale. The script it follows is `~/SynologyDrive/Python_Scripts/dragon_curve/dragon_curve.py`. There, letters are laid on the paperfold and read back in page order. Here, tiles and short runs of frames take those places. The frames stay the frames. Only their order changes.

Scale keeps one tile rearrangement for every frame, so the picture stays scrambled and the motion stays continuous. Fold moves runs of frames, the way Dragonfold moves grains of audio. Both does the two together.

Any player plays the scramble. Restore, with the same phrase, puts the tiles and the runs back. The phrase is not stored in the file. The movie is H.264, so the restored picture carries the small change the codec makes.

This is a rearrangement. It is not a substitute for FileVault. See `SECURITY.md`.

## Build

Dragonreel is the Reel section of The Dragon. Its source is `Sources/Dragonreel`.

```bash
cd "/Users/timbestler/The Dragon"
./build-app.sh
```

## Window

The window opens on a two-second reel, so Fold works before you drop a file. Drop a movie anywhere. This version fits each frame inside 1920×1080 and does not scale a smaller frame up. **Preview** keeps the first 20 seconds, or 600 frames, and stops sooner when the frame cache is full. At 1080p that is about eight seconds. **Full movie** keeps the whole file when the temporary files for the loaded frames, the folded frames, and the sound will fit. A smaller picture runs longer. A long soundtrack is kept in a temporary file.

The curve under the movie is the pass you are looking at. North is up. The dot is where the pen starts. The arrows step through the passes. The curve draws at most 4,096 segments of that pass.

**Phrase** is case sensitive. Leave it empty for the plain curve. **Passes** is Automatic or 1 through 7. Automatic is one pass with an empty phrase, and 4 to 7 when there is a phrase. `paper` is 7. `Dragon_Curves` is 6.

**Scale** moves the same squares on every frame. Tile 16 is the default. A strip along the right or the bottom that does not fill a tile stays where it is. **Fold** moves runs of frames. Run 8 is the default. A longer run keeps the motion inside it. Run 1 flickers. A remainder shorter than one run stays at the end. **Both** does the two rearrangements together. They can be undone in either order.

Fold is ⌘F. Restore is ⌘D. Export Folded Movie is ⌘E. Save Plain Movie is ⌘S. Open is ⌘O. Back to the reel is ⌘K. Space plays and stops, unless the phrase field is focused.

The original is never replaced. `clip.mp4` is offered as `clip.dragon.mp4`. A plain copy is offered as `clip.copy.mp4`.

**Write the fold note** is on. The note is the movie's description. Players that expect a normal MP4 still play it. The note records the axis, the tile, the run, the pass count, and whether a phrase was used. It does not record the phrase. See `FORMAT.md`.

Turn the note off and the MP4 is an ordinary movie. Open that file, turn on **Treat as folded**, set the same phrase and settings, and Restore.

The sound is cut into one slice per frame and folded with the picture. Scale cuts that slice into the same pieces as the tiles. A larger tile keeps a longer piece of sound together. When a frame has fewer samples than tiles, each sample moves. Fold moves the whole slice with the frame, so a longer run keeps the sound inside it in order. The movie writes that sound as AAC. Restore puts the loaded samples back. The codec's own change stays.

A wrong phrase still produces a movie. It is not the original. Fold Again, in the File menu, folds the scramble a second time. Restore undoes only the last fold.

## Command line

```bash
Dragonreel --reel --out ~/Desktop/reel.dragon.mp4
Dragonreel --input clip.mp4 --key paper --passes 4 --axis both --tile 16 --run 8 --out ~/Desktop/clip.dragon.mp4
Dragonreel --restore --input ~/Desktop/clip.dragon.mp4 --key paper --out ~/Desktop/clip.restored.mp4
Dragonreel --self-test
```

`--out` replaces a file already at that path. It refuses to replace the input, and the path has to end in `.mp4`. `--plain` leaves the fold note out. `--axis` is `scale`, `fold`, or `both`. `--span` is `preview` or `full`. Preview is the default. Restore reads the whole movie unless `--span preview` is set.

`Hello` with no phrase is `olleH` in the text curve this engine copies. `paper` is `loeHl`. The movie fold uses that same plan.

## Tests

`Dragonreel --self-test` checks the paperfolding turns, the text vectors above, the 1080p fit, a tile fold that keeps the same map on every frame, a run fold with a short tail, a one-frame run that flickers, scale and fold together, the sound moving with those same maps, a movie a player can open, a note, and a command-line round trip.
