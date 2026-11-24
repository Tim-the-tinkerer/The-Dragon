# Dragonfold

A Mac window that scrambles audio with the Heighway dragon, then writes a WAV you can play.

The curve is the same transposition as Dragon Curve. The script it follows is `~/SynologyDrive/Python_Scripts/dragon_curve/dragon_curve.py`. There, letters are laid on the paperfold and read back in page order. Here, samples take those places. The samples stay the samples. Only their order changes.

A player plays the scramble. Restore, with the same phrase, puts every sample back. The phrase is not stored in the file.

This is a rearrangement. It is not a substitute for FileVault. See `SECURITY.md`.

## Build

Dragonfold is the Fold section of The Dragon. Its source is `Sources/Dragonfold`.

```bash
cd "/Users/timbestler/The Dragon"
./build-app.sh
```

## Window

The curve on the left is the pass you are looking at. North is up. The dot is where the pen starts. The arrows step through the passes. The picture draws at most 4,096 segments of that pass.

The window opens on a two-second arpeggio, so Play works before you drop a file. Drop a WAV, AIFF, MP3, M4A, or CAF anywhere. The first 10 minutes are loaded. A mono file stays mono. More than two channels keep the first two.

**Phrase** is case sensitive. Leave it empty for the plain curve. **Passes** is Automatic or 1 through 7. Automatic is one pass with an empty phrase, and 4 to 7 when there is a phrase. `paper` is 7. `Dragon_Curves` is 6.

**Sample** gives each channel its own dragon. The left channel walks the phrase. The right channel walks the same passes with the fold turned over, so a left sample stays on the left and the two sides are not the same scramble. A full loaded song fits. A long one can take about a minute. **Frame** moves both channels of one moment together. **Grain** moves a short block together, so scraps of the recording stay recognizable. Grain 1024 is about 23 ms at 44.1 kHz. A remainder shorter than one grain stays at the end, so the fold can be undone.

**Reverse right turns** is off. Turn it on and a grain plays backward when that step of the curve turns right. A left turn plays forward. The samples are still only reordered. Restore uses the same phrase. The note records the switch. It does not record the phrase.

Fold is ⌘F. Restore is ⌘D. Export Folded WAV is ⌘E. Save Plain WAV is ⌘S. Open is ⌘O. Back to the tone is ⌘K. Space plays and stops, unless the phrase field is focused.

Volume is playback only. The file is written at full level. The original is never replaced. `song.wav` is offered as `song.dragon.wav`.

**Write the fold note** is on. The note is a `dcaf` chunk after the audio. Players that expect a normal WAV still play it. The note records the unit, the grain, the pass count, and whether a phrase was used. It does not record the phrase. See `FORMAT.md`.

Turn the note off and the WAV is ordinary PCM. Open that file, turn on **Treat as folded**, set the same phrase and settings, and Restore.

A wrong phrase still produces audio. It is not the recording. Restore again with another phrase. The folded audio stays until you fold something else.

Fold Again, in the File menu, folds the scramble a second time. Restore undoes only the last fold.

## Command line

```bash
Dragonfold --tone --out ~/Desktop/tone.dragon.wav
Dragonfold --input song.wav --key paper --passes 4 --grain 1024 --out ~/Desktop/song.dragon.wav
Dragonfold --restore --input ~/Desktop/song.dragon.wav --key paper --out ~/Desktop/song.restored.wav
Dragonfold --self-test
```

`--out` replaces a file already at that path. It refuses to replace the input. `--plain` leaves the fold note out. `--unit` is `sample`, `frame`, or `grain`.

`Hello` with no phrase is `olleH` in the text curve this engine copies. `paper` is `loeHl`. The audio fold uses that same plan.

## Tests

`Dragonfold --self-test` checks the paperfolding turns, the text vectors above, a grain fold with a short tail, a frame fold against the curve, a WAV a player can open, a tampered note, and a command-line round trip.
