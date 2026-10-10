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

## Travel assistant (demo)

The chat button on the map opens a travel assistant that summarises live
disruptions and answers public transport questions. For demos it runs on
your Mac's Claude Code (Haiku), so no API key goes in the app:

```sh
python3 tools/chat_bridge.py                 # simulator (127.0.0.1:8787)
python3 tools/chat_bridge.py --host 0.0.0.0  # phone on the same Wi-Fi
```

For a phone, add `ChatBridgeURL` (e.g. `http://192.168.1.20:8787`) to
`Secrets.plist`. The assistant's instructions are in
`tools/chat_assistant_prompt.md`. Each chat starts with a snapshot built from
the app's live feeds (Luas line status, DART lateness, bus cancellations and
delays).

## Data

`hackUCD-LeapFrog/Resources/*.json` is generated from TFI's static GTFS feed:

```sh
python3 tools/build_static_data.py
```

## Debug options

Launch arguments (Debug builds only):
- `-syntheticBuses 1500` — fake moving buses, for load testing without an API key
- `-initialSpan 0.02` — start zoomed in
- `-chat 1` — open the travel assistant at launch
