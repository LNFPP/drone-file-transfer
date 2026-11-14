# Drone File Transfer (Mac)

Copies DJI drone footage into community/location folders using CSVs exported from the Lot Shots Drone app:

- **Flight Log CSVs** sort photos and videos (JPG, DNG, MP4, MOV, skipping 360s) into `Communities/<Community>/Drone/MM.DD.YY/Photos` and `/Videos`.
- **360s CSVs** find each lot's 360 on the drone and copy it as `<Community>_Lot<N>.jpg` into `Communities/<Community>/360's/MM.DD.YY`. 360s no row claims go to the Unmatched 360s folder.

Files are only ever copied (each copy is checked against the original); nothing on the drone is moved or deleted.

**Download:** https://github.com/LNFPP/drone-file-transfer/releases/latest/download/DroneFileTransfer-mac.dmg

Open the .dmg and drag Drone File Transfer into Applications. After that, use **Check for Updates** in the app (Setup tab or app menu).

Unsigned app: on first open, go to System Settings → Privacy & Security → Open Anyway.

Built automatically by GitHub Actions on every push to `main` (universal: Apple Silicon + Intel, macOS 13+).
