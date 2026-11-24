# Changelog

## 1.0.8

- With Pair on, Export, Restore, and Fold Again use the two pictures on screen. A single fold kept behind them stays put until Pair is turned off.
- The second picture of a folded pair stays until that pair is restored.
- Restoring the night card leaves it as the stand-in, so a drop can replace it again.
- Fold Again keeps the pair note when the new unit is too large. Treat as folded restores a pair once.
- Holding a key repeats as usual. The pass keys still ignore the repeat.

## 1.0.7

- Pairing no longer hides a folded picture. Restore it first, then turn Pair on.
- A PNG transparency chunk keeps its transparency. A fold note with a tile larger than 4096 is not trusted.
- The File menu follows the buttons while a fold is running. A hard link of the original file is left alone.
- `--passes=`, `--unit=`, and `--tile=` are read from the command line. A loader warning is printed with the result.

## 1.0.6

- Pair pictures: drop a file on the right well to set the second picture. While the night card is still there, a drop outside the left well replaces it.

## 1.0.5

- Pair pictures is optional. Two pictures share one dragon, and pixels, tiles, or strips can cross. The export is one PNG with the first picture above the second. The fold note is version 4. Older notes still restore.

## 1.0.4

- Split channels is optional, and it is a pixel fold. Red walks the phrase, blue the mirror, and green the plain curve. The fold note is version 3 when it is on. Older notes still restore.

## 1.0.3

- Spin tiles is optional. Each square turns with the pen. The fold note is version 2 when it is on. Older notes still restore.

## 1.0.2

- Rows and Columns cut the picture into ribbons. The edge that does not fill a strip stays put.

## 1.0.1

- Pixel mode folds any picture the window can open, including photos larger than 1.5 megapixels.

## 1.0.0

- Fold a picture on the Heighway dragon and export a PNG that still opens.
- Pixel and tile. Automatic passes, or 1 through 7.
- A `dsCl` note in the PNG records the fold. The phrase is not stored.
- Restore puts the pixels back. The original file is left alone.
