# Seat Weave App Store assets

Five portrait PNGs in `screenshots/6.5-inch/`, ordered for upload:

1. Seating assignments
2. Guest roster
3. Pair preferences
4. Compare plans
5. Guest-facing sharing preview

Each image is a native 1284 × 2778 simulator capture, an accepted 6.5-inch App Store size. See [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

Captured September 23, 2026 with Xcode 27.0 (27A266a), iOS 26.5, and an iPhone 13 Pro Max simulator. All guest names and arrangements are fictional. The screenshot build succeeded; the five images were visually reviewed. This capture is not the repository's pinned CI validation or a signed release build.

`description.txt` contains the full App Store description; `metadata.md` includes the suggested subtitle, promotional text, and keywords. Nothing has been uploaded or submitted to App Store Connect.

The user's supplied artwork is installed in all eight existing icon files under `App/Assets.xcassets/AppIcon.appiconset`. The 1024px marketing icon and smaller renditions are opaque PNGs.

To regenerate on a Mac with Xcode and iOS 26.5 installed:

```sh
python3 Scripts/capture_app_store.py
```

The script makes a temporary project copy, seeds a fictional gathering, selects each real app screen, builds unsigned, and captures a dedicated simulator. It deletes the simulator and temporary build afterward. Production app source and existing simulator data are untouched. The build log is saved under `build/app-store/`.
