# Changelog

## 2.0.0

The window follows the current `dragon_curve.py`.

Notes are the modern character permutation. `Hello` with no phrase is `olleH`. `Hello` with `paper` is `loeHl`. `TEXT/1` and `TEXT/2` are retired, and so is the version 1 key. An earlier release can still open those notes. Character header, off by default, writes a `DRAGON-CURVE-DATA/3` character file so the pass count is stored.

Files still use character, hex digit, byte, and bit. Scramble name hides the original name in the header and writes a `dc-` name. Decrypt restores that name when it is free, and a wrong phrase writes nothing.

A folder becomes one package. Deflate or Store packs the tree. The dragon curve then rearranges each chunk. Cross-chunk weave writes `DRAGON-CURVE-FOLDER/2`. Without it the package is `DRAGON-CURVE-FOLDER/1`. The package checksum reports a wrong phrase or a damaged file. It is not a seal. Originals are not replaced.

Map pass draws the note as it enters that pass.

## 1.0.0

First window for the Heighway dragon transposition in `dragon_curve.py`.

Notes used the version 1 and version 2 text format. Files used the version 3 character, hex digit, byte, and bit formats. The phrase was not stored. The curve of the plaintext was drawn in the window. Originals were not replaced.

The Passes menu kept a choice of 7. That count was what the curve, the note, and a file used. A numbered note with the version header on stored the count.
