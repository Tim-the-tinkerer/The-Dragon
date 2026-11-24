# Dragon Curve

A Mac window for the Heighway dragon transposition in `dragon_curve.py`.

The curve is a strip of paper folded in half, over and over, always the same way, then opened so each fold is a right angle. The note is laid on that path, one character on each segment. The ciphertext is those same characters read from the top of the page downward, and from left to right along a row.

A phrase makes 4 to 7 passes. Each pass has its own fold, starting direction, starting segment, and one of eight ways to read the page. Decrypting undoes the passes, last first. The same note and the same phrase always give the same result.

This is a rearrangement. The letters stay the letters. It is not a substitute for FileVault. See `SECURITY.md`.

The script it follows is `~/SynologyDrive/Python_Scripts/Ciphers/dragon_curve/dragon_curve.py`. A note saved from this window opens in that script, and a file or folder package from that script opens here.

## Build

Dragon Curve is the Curve section of The Dragon. Its source is `Sources/DragonCurve`.

```bash
cd "/Users/timbestler/The Dragon"
./build-app.sh
```

## Window

The curve on the left is the plaintext on the chosen map pass. North is up. The dot is where the pen starts. Map pass appears when the phrase makes more than one pass. Pass 1 is the note as it enters that pass.

The phrase is case sensitive. Leave it empty for one pass on the plain curve, which turns `Hello` into `olleH`. A phrase turns `Hello` into `loeHl`.

**Passes** is Automatic or a number from 1 to 7. Automatic lets the phrase choose 4, 5, 6, or 7. Choosing 7 uses seven passes. The count is shown under the curve.

**Character header** is off by default. Off, the note is the rearranged characters alone, the same as the script. On, the note is a `DRAGON-CURVE-DATA/3` character file, so the pass count is stored. The phrase is not in that line. `TEXT/1` and `TEXT/2` notes are retired. An earlier release can still open them. `--classic` is retired with them.

Encrypt is ⌘E. Decrypt is ⌘D. Clear is ⌘K and keeps the phrase. Decrypt reads the ciphertext box when it has something in it, and otherwise reads the plaintext box.

Drop a file or a folder anywhere on the window. Encrypt File writes a sibling and leaves the original where it is. `note.txt` becomes `note.dragon.txt`. If that name is already there, the write is refused. Decrypt File reads a version 3 header and uses the unit and pass count stored there. A folder package is refused there. Use Decrypt Folder.

**Scramble name** stores the original file name in the header and writes a neutral `dc-` name. Decrypt puts the original name back when that name is free. A wrong phrase is refused, and nothing is written.

**Folder** packs a directory as a ZIP, Deflate or Store, then rearranges it in chunks. The folder unit is byte, hex digit, or bit. Cross-chunk weave mixes distant chunks and writes `DRAGON-CURVE-FOLDER/2`. Without it the package is `DRAGON-CURVE-FOLDER/1`. Those numbers are the folder formats. They are not the retired text formats. Decrypt Folder reads the settings from the package. The output has to sit outside the source folder. A folder that is already there is left alone.

Character mode needs UTF-8. Hex digit splits each byte into two nibbles. Byte reorders the bytes. Bit reorders every bit, most significant bit first, and stops at 1 MB for a single file. Byte and character stop at 8 MB. Hex digit stops at 4 MB. A folder package is read in chunks and is not held to those caps.

## Command line

```bash
DragonCurve --encrypt Hello
DragonCurve --encrypt --key paper Hello
DragonCurve --decrypt --key paper loeHl
DragonCurve --encrypt --header --key paper --passes 7 Hello
DragonCurve --encrypt-file --unit byte --key paper --passes 4 note.txt
DragonCurve --encrypt-file --unit byte --key paper --scramble-name note.txt
DragonCurve --decrypt-file --key paper note.dragon.txt
DragonCurve --encrypt-folder --compression store --cross-weave --key paper Folder
DragonCurve --decrypt-folder --key paper Folder.dragon
DragonCurve --self-test
```

Text mode does not write a header unless `--header` is set. That header is `DRAGON-CURVE-DATA/3` in character mode. File mode writes a `DRAGON-CURVE-DATA/3` header unless `--no-header` is set. The file unit defaults to byte. `--passes` is 1 through 7. Leaving it off uses the phrase's own pass count, which is 4 to 7 when a phrase is set, and 1 when it is empty.

`--scramble-name` is only for encryption, and it needs a header. `--cross-weave` and `--compression` are for folder encryption. Folder decryption reads the unit, the pass count, the compression, and the weave from the package.

`Hello` with no phrase prints `olleH`. `--key paper` prints `loeHl`.

## Tests

`DragonCurve --self-test` checks the published paperfolding turns, the FNV-1a and SplitMix64 vectors, the notes above, a byte, nibble, and bit sample, a scrambled file name, and a folder round trip that leaves the original in place.
