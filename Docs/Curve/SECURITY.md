# Security

Dragon Curve rearranges a message. It does not change the characters, nibbles, bytes, or bits themselves. Someone who can see the ciphertext can see every value that was in the plaintext. Only the order is different.

The phrase is hashed with FNV-1a, 64 bits, and the passes are drawn with SplitMix64. That is a fast hash, not a password hash. A short or common phrase can be guessed. There is no salt in the file, so the same phrase and the same note always produce the same ciphertext.

A data file that does not scramble its name has no checksum. A wrong phrase, or an edited ciphertext, comes back as a different rearrangement. It is not reported as a failure.

A scrambled file name carries an 8-byte checksum of the original name. A wrong phrase fails that check, and nothing is written. The checksum detects a mismatch. It does not stop someone who can rewrite the file from inventing a new token.

A folder package stores the SHA-256 of the ZIP it was built from. Decoding checks that sum, and a woven package also rejects padding that is not zero. A wrong phrase or a damaged package is reported, and the destination folder is not created. The sum is a checksum. It is not a seal. Someone who can rewrite the package can recompute it.

The header records the algorithm, the unit, the pass count, and whether a phrase was used. It does not record the phrase. Changing the header can make the file open with the wrong algorithm.

Do not use this for private files, passwords, or anything you need to keep from another person. Use FileVault, or a program that authenticates the ciphertext, for that.

The original file is never replaced. A sibling that already exists is left alone. A folder is not replaced. Save asks for a new path and refuses the note that was opened.
