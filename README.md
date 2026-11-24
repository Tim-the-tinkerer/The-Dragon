# The Dragon

One Mac window for the four Heighway dragon folds. Each fold keeps its own section.

| Section | Folds |
| --- | --- |
| Dragon Curve | A note, a file, or a folder |
| Dragonscale | A picture |
| Dragonfold | Audio |
| Dragonreel | A movie |

The rail on the left switches sections. ⌘1 through ⌘4 do the same. A section keeps what you were doing when you leave it and come back. Playback stops when you leave Fold, and a movie pauses when you leave Reel.

Each section is the app it came from. The phrase, the passes, and the file formats are unchanged. The phrase is not stored. This is a fold, not a lock.

## Build

Xcode is required.

```bash
cd "/Users/timbestler/The Dragon"
./build-app.sh
```

`./build-app.sh --no-launch` builds, runs every self-test, signs the app, and leaves it closed. The app is `The Dragon.app`, bundle id `com.tim.thedragon`, version 1.0.0.

Source for the window is in `Sources/TheDragon`. Source for each fold is in `Sources/DragonCurve`, `Sources/Dragonscale`, `Sources/Dragonfold`, and `Sources/Dragonreel`. Notes for each fold are in `Docs`.

## Command line

```bash
TheDragon --self-test
TheDragon curve --encrypt Hello
TheDragon scale --help
TheDragon fold --help
TheDragon reel --help
```

`curve`, `scale`, `fold`, and `reel` take the arguments of that fold. `--help` on a section prints them.

## Formats

- Curve: `Docs/Curve/FORMAT.md`
- Scale: `Docs/Scale/FORMAT.md`
- Fold: `Docs/Fold/FORMAT.md`
- Reel: `Docs/Reel/FORMAT.md`
