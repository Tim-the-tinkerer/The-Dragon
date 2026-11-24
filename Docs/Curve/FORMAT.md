# Dragon Curve formats

Dragon Curve 2.0.0 writes the same packages as `dragon_curve.py`. None of them store the phrase. The bytes after the header are a rearrangement of the original units.

`DRAGON-CURVE-TEXT/1` and `DRAGON-CURVE-TEXT/2` are retired. Opening one reports that an earlier release can still read it. The old version 1 key is retired with them. The `1` and `2` on a folder package are folder formats, not those text formats.

## Text

A note is the modern character permutation, with no envelope:

```text
loeHl
```

An empty phrase is one plain pass. `Hello` becomes `olleH`. Any other phrase is 4 to 7 passes drawn from an FNV-1a 64-bit hash with SplitMix64. `Hello` with `paper` is `loeHl`. A chosen count, from 1 to 7, repeats that many passes. The same count has to be selected again to undo a note that has no header.

**Character header** writes a character-mode data file so the count is stored. The line is ASCII, then a newline, then the rearranged characters:

```text
DRAGON-CURVE-DATA/3 mode=character passes=7 key=1
loeHl
```

`key=1` means a phrase was used. `key=0` means the phrase was empty. The phrase itself is not recorded. A wrong phrase is not detected on a note. It produces a different rearrangement.

## Data, version 3

A file is:

```text
DRAGON-CURVE-DATA/3 mode=byte passes=4 key=1
```

then a newline, then the rearranged payload. `mode` is `character`, `hex`, `byte`, or `bit`. `passes` is one digit, 1 through 7. `key` is `0` or `1`.

Character mode splits the file into Unicode code points and joins them back as UTF-8. The file has to be valid UTF-8, and the byte length can change. Hex digit mode splits each byte into two nibbles, high nibble first. Byte mode reorders the bytes. Bit mode reorders every bit, most significant bit first. In nibble, byte, and bit mode the payload length matches the original.

An unmarked file is read with the unit and pass count chosen in the window. Passes left on Automatic use the phrase's own count. Choosing 7 writes `passes=7` and runs seven passes. Omitting the unit on the command line uses byte.

A scrambled name adds ` name=TOKEN` to that same line:

```text
DRAGON-CURVE-DATA/3 mode=byte passes=4 key=1 name=TOKEN
```

The token is the original file name, a short checksum, and a fixed marker, rearranged with the filename key and then written as URL-safe base64 without padding. Decrypt checks the checksum before it writes. A wrong phrase writes nothing. The visible file is `dc-` plus 24 hex digits and `.dragon`.

A data file with no name token has no checksum. A wrong phrase comes back as a different rearrangement.

## Folders

A folder is packed as a ZIP, then rearranged in chunks. Deflate compresses the members. Store leaves them uncompressed. The ZIP is built so Python's zipfile can read it, including names that are not ASCII.

Without cross-chunk weave the header is `DRAGON-CURVE-FOLDER/1`. With the weave it is `DRAGON-CURVE-FOLDER/2`. One example:

```text
DRAGON-CURVE-FOLDER/2 mode=byte passes=4 key=1 chunk=16384 bytes=12000 sha256=HEX weave=16 name=TOKEN
```

`mode` is `byte`, `hex`, or `bit`. Character mode is not used for a folder. `chunk` is 16384 bytes for byte mode, 8192 for hex digit, and 2048 for bit. `bytes` is the length of the ZIP before weaving. `sha256` is the SHA-256 of that ZIP. It is a checksum, not a seal. `weave=16` is present only on format 2. `name=TOKEN` is present only when the package name was scrambled.

Packaging order is ZIP, then the weave when it is on, then the dragon permutation on each chunk. Decoding reverses that order and checks the checksum before it restores the tree. A wrong phrase or a changed byte is reported, and the destination is not created. The restored names keep the spelling stored in the ZIP, including a composed `café`.

The weave splits each chunk into 16 stripes and moves those stripes among distant chunks. The last partial chunk is padded with zeros for the weave and trimmed afterward. Nonzero padding is an error. Symbolic links and special files are refused. Empty directories and hidden files are kept.

Decrypt Folder ignores a chosen unit, pass count, compression, and weave. Those settings are in the package.

## Names

Encrypting `note.txt` writes `note.dragon.txt` in the same folder. Decrypting `note.dragon.txt` writes `note.txt` when that name is free. Decrypting a name with no `.dragon` marker writes `note.plain.txt`. A scrambled name decrypts to the stored file name when that name is free.

A folder without a scrambled name is written as `Name.dragon` beside the source. Decrypting it restores the folder name stored in the package. A name that is already there is left alone. The original is never the output. The encoded folder file has to sit outside the source folder.

Save from the note panel asks for a path. It will not replace the note that was opened.
