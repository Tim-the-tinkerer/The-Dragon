# Dragonscale PNG

A folded export is an ordinary 8-bit RGBA PNG. The picture is the scrambled pixels. A viewer reads `IHDR` and `IDAT` and shows them.

The fold note is a private ancillary chunk named `dsCl`. It is written after `IDAT` and before `IEND`. The phrase is not in the chunk.

```
signature
IHDR     8-bit RGBA, no interlace
sRGB
IDAT     zlib, filter none on each row
dsCl     18-byte fold note
IEND
```

The note, little-endian:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | Version. This app writes 1, 2 when tiles turn, 3 when the channels split, or 4 when two pictures share the dragon. |
| 1 | 1 | Unit. 1 pixel, 2 tile, 3 rows, 4 columns. |
| 2 | 1 | Passes, 1 through 7. |
| 3 | 1 | Version 1: 1 if a phrase was used, otherwise 0. Version 2: bit 0 is the phrase, bit 1 means the tiles turned. Version 3 adds bit 2 when red, green, and blue each walk their own curve. Version 4 uses those same three flag bits. The version itself means the file is a pair. |
| 4 | 2 | Tile side, or the thickness of a strip, in pixels. 1 for pixel mode. |
| 6 | 4 | Width. Must match `IHDR`. |
| 10 | 4 | Height. Must match `IHDR`. |
| 14 | 4 | CRC-32 of the raw RGBA bytes, row by row, with no filter byte. |

PNG chunk lengths and chunk CRCs stay big-endian, the way every PNG chunk is written. Only the 18 bytes inside `dsCl` are little-endian.

Restore checks the note against the pixels. If the CRC or the sizes do not match, the file still opens and Restore is not offered from the note.

A strip that does not fill a tile is not a segment. It stays in place. The tile side and the width and height are enough to find it again.

Pixel mode lays one pixel on each segment, in row order from the top. Tile mode lays one square on each segment, also in row order. Rows lay one horizontal ribbon on each segment, full width, from the top. Columns lay one vertical ribbon on each segment, full height, from the left. Every full segment is the same size. A row fold leaves a short bottom edge in place. A column fold leaves a short right edge in place.

Version 2 is the same 18 bytes. Bit 1 means each pass turns a square clockwise by the heading of the step it came from. East is 0°. North is 90°. West is 180°. South is 270°. Image rows run downward. Restore turns the other way and undoes the passes last first. A fold that does not turn tiles stays version 1.

Version 3 is the same 18 bytes. Bit 2 means a pixel fold split the channels. Red follows the phrase. Blue follows those passes with the fold turned over. Green follows that many passes of the plain curve. Alpha stays on its pixel. Restore walks each channel back. A fold that does not split the channels stays version 1 or 2.

Version 4 is the same 18 bytes. The version means two pictures were mixed. The PNG is the first picture on top of the second, including the edges that stayed put. Width is the picture width. Height is twice the picture height, so the file can be taller than one picture. Each half is still at most 8192 pixels on a side. The flag bits are the version 3 bits. Restore splits the file at half the height and walks the pieces back.

The pieces that move are packed without those leftover edges, so a remainder never sits between the two pictures. Columns sit side by side on the curve. Pixels, rows, and tiles stack. A picture smaller than one segment is still one segment, so the two pictures can trade places whole. The file itself is always the full pictures, one above the other. A fold of one picture stays version 1, 2, or 3.

Turn the note off and this chunk is absent. The PNG is only the picture.

Dragonscale reads its own files by inflating the rows, so the pixels that come back are the pixels that were written. A JPEG or HEIC is decoded by ImageIO first. The fold then rearranges those loaded pixels, and the export is the PNG above.
