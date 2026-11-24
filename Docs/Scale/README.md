# Dragonscale

A Mac window that scrambles a picture with the Heighway dragon, then writes a PNG you can open.

The curve is the same transposition as Dragonfold and Dragon Curve. The script it follows is `~/SynologyDrive/Python_Scripts/dragon_curve/dragon_curve.py`. There, letters are laid on the paperfold and read back in page order. Here, pixels take those places. The pixels stay the pixels. Only their order changes.

Any viewer opens the scramble. Restore, with the same phrase, puts every pixel back. The phrase is not stored in the file.

This is a rearrangement. It is not a substitute for FileVault. See `SECURITY.md`.

## Build

Dragonscale is the Scale section of The Dragon. Its source is `Sources/Dragonscale`.

```bash
cd "/Users/timbestler/The Dragon"
./build-app.sh
```

## Window

The window opens on a small card, so Fold works before you drop a file. Drop a PNG, JPEG, TIFF, GIF, HEIC, or WebP anywhere. A picture longer than 8192 pixels on a side is loaded as a smaller copy.

The plain picture stays on the left. The scramble appears on the right. The curve under them is the pass you are looking at. North is up. The dot is where the pen starts. The arrows step through the passes. The curve draws at most 4,096 segments of that pass.

**Phrase** is case sensitive. Leave it empty for the plain curve. **Passes** is Automatic or 1 through 7. Automatic is one pass with an empty phrase, and 4 to 7 when there is a phrase. `paper` is 7. `Dragon_Curves` is 6.

**Pixel** puts every pixel on its own segment. It works on any picture the window opens. A large photo can take a few seconds. The status line shows the pass. **Tile** moves a square scrap together, so pieces of the picture stay recognizable. Tile 16 is the default. A strip along the right or the bottom that does not fill a tile stays where it is.

**Rows** cut horizontal ribbons the full width of the picture. **Columns** cut vertical ribbons the full height. The same sizes, 4 through 128, set how thick a ribbon is. The bottom edge of a row fold, or the right edge of a column fold, stays where it is when it does not fill a ribbon.

**Spin tiles** is off. Turn it on and each square turns with the pen. East stays upright. North is 90°. West is 180°. South is 270°. Another pass turns the square again. A one-pixel tile does not turn. Pixel and ribbons do not turn. The note records the turn, and Restore uses the note.

**Split channels** is off. It is a pixel fold. Red walks the phrase. Blue walks the same passes with the fold turned the other way. Green walks the plain curve. Alpha stays on its pixel. A photo becomes a colored ghost of the curve. The note records the split, and Restore puts each channel back.

**Pair pictures** is off. Turn it on and two pictures share one dragon. The window opens a night card beside the day card, or you open a second image. Drop the second picture on the right well. While the night card is still there, a drop anywhere but the left well replaces it. If the first picture is still the day card and the dropped picture is a different size, the card is fitted to that picture. Pixels, tiles, or strips can cross from one picture into the other. A scrap that does not fill a segment stays in its own picture. Restore uses the same phrase and puts both pictures back. The export is one PNG, the first picture on top and the second below. If the second picture is a different size, Dragonscale fits it to the first and says so. Restore returns those fitted pixels.

Fold is ⌘F. Restore is ⌘D. Export Folded PNG is ⌘E. Save Plain PNG is ⌘S. Open is ⌘O. Back to the card is ⌘K.

The original is never replaced. `photo.png` is offered as `photo.dragon.png`. A plain copy is offered as `photo.copy.png`.

**Write the fold note** is on. The note is a `dsCl` chunk in the PNG. Viewers that expect a normal PNG still open it. The note records the unit, the tile, the pass count, and whether a phrase was used. It does not record the phrase. See `FORMAT.md`.

Turn the note off and the PNG is an ordinary picture. Open that file, turn on **Treat as folded**, set the same phrase and settings, and Restore.

A wrong phrase still produces a picture. It is not the original. Fold Again, in the File menu, folds the scramble a second time. Restore undoes only the last fold.

## Command line

```bash
Dragonscale --card --out ~/Desktop/card.dragon.png
Dragonscale --input photo.png --key paper --passes 4 --tile 16 --out ~/Desktop/photo.dragon.png
Dragonscale --input photo.png --mate other.png --key paper --out ~/Desktop/photo.dragon.png
Dragonscale --card --pair --out ~/Desktop/card.dragon.png
Dragonscale --restore --input ~/Desktop/photo.dragon.png --key paper --out ~/Desktop/photo.restored.png
Dragonscale --self-test
```

`--out` replaces a file already at that path. It refuses to replace the input, and the path has to end in `.png`. `--plain` leaves the fold note out. `--unit` is `pixel`, `tile`, `row`, or `column`. `--tile` is the square side, or how thick a ribbon is. `--spin` turns tiles with the pen. `--split` gives red, green, and blue their own curves in pixel mode. `--pair` mixes a second picture through the same dragon. `--mate` is that picture. With `--card`, the night card is the second picture when `--mate` is left out. A pair export is one PNG, twice as tall, and `--restore` writes that stack back without the note.

`Hello` with no phrase is `olleH` in the text curve this engine copies. `paper` is `loeHl`. The picture fold uses that same plan.

## Tests

`Dragonscale --self-test` checks the paperfolding turns, the text vectors above, a tile fold with an edge that stays put, a pixel fold against the curve, a PNG a viewer can open, a note whose pixels were changed, and a command-line round trip.
