# LeapFrog

iOS app showing live Dublin buses, Luas trams and DART trains on a map, using the
[NTA GTFS-Realtime API](https://developer.nationaltransport.ie/), the Irish Rail
realtime API and Luas forecasts.

## Setup

1. Copy `Secrets.example.plist` to `hackUCD-LeapFrog/Secrets.plist` and paste your NTA API key
   (that file is gitignored — never commit it).
2. Open `hackUCD-LeapFrog.xcodeproj` and run on an iOS 18+ simulator or device.

Each NTA key is rate-limited (TripUpdates ≈ once a minute), and every running copy of the app
shares that limit — run one copy per key at a time.

## Data

`hackUCD-LeapFrog/Resources/*.json` is generated from TFI's static GTFS feed:

```sh
python3 tools/build_static_data.py
```

## Debug options

Launch arguments (Debug builds only):
- `-syntheticBuses 1500` — fake moving buses, for load testing without an API key
- `-initialSpan 0.02` — start zoomed in
