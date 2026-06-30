# DustWatch

[中文说明](README.zh-CN.md)

DustWatch is a macOS menu bar app for tracking thermal behavior over time. It
records CPU/GPU temperature, fan RPM, and workload, then uses the history to
surface possible cooling degradation such as dust buildup.

The app is useful for two groups:

- Users who want a quiet background monitor and a clear "do I need to clean my
  Mac?" signal.
- Developers who want a small SwiftUI/AppKit/SQLite project for local sensor
  collection, charting, and thermal-risk analysis.

DustWatch is still beta software. The sensor and risk model are practical, but
the dust-risk algorithm has not been validated across enough machines, rooms,
seasons, workloads, and cooling designs. User reports, counterexamples, data
analysis, and implementation ideas are welcome.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon is the primary target
- Intel builds are produced by the release workflow, but sensor decoding is
  best effort
- No Apple Developer account is needed for local builds
- Xcode command-line tools are enough for building from source

DustWatch does not use App Sandbox. Reading SMC sensors requires private macOS
interfaces that are unavailable to sandboxed apps.

## Install

The easiest path is to download the latest DMG from GitHub Releases:

<https://github.com/NormanZyq/dust-watch-mac/releases>

Open the DMG, drag `DustWatch.app` to `/Applications`, then launch it. Current
beta builds are ad-hoc signed, so macOS may block the first launch. If that
happens, open **System Settings > Privacy & Security** and choose **Open
Anyway** for DustWatch.

On launch, DustWatch opens the dashboard and keeps a menu bar icon running in
the background. The default sample interval is 60 seconds.

## Daily Use

- **Overview** shows today's peaks, recent trends, and the current dust-risk
  level.
- **Live** shows recent raw samples.
- **History** shows 24h, 7d, 30d, 90d, or all data with raw/hourly/daily
  aggregation and CSV export.
- **Heatmap** shows daily thermal intensity over weeks or months.
- **Compare** shows the current cooling-loss comparison when the model has
  enough evidence.
- **Settings** changes sampling, alert thresholds, the recent analysis window,
  notifications, demo data, and cooling-reference calibration.

The Overview tab is the default landing page. It keeps the current dust-risk
state visible above the daily temperature and fan cards, then continues into the
24-hour and 7-day trend charts.

![DustWatch overview dashboard](<screenshots/1. dashboard-overview.png>)

The History tab is for exploration. It supports raw, hourly, and daily views,
shows temperature, fan, and cooling-loss series together, and exposes exact
values on hover.

![History tab with daily aggregation and hover details](<screenshots/2-2. history-panel-without-risk-purple-line.png>)

With longer demo or real histories, the purple cooling-loss trend makes it
easier to see how the risk model's signal moves over time.

![History tab showing a 30-day cooling-loss trend](<screenshots/3-2. demo-data-history-with-risk-purple-line.png>)

Settings are saved immediately. The calibration button should be used only when
the machine is known to be thermally healthy, for example right after cleaning
dust. Resetting calibration keeps existing samples and returns the model to
automatic reference learning.

If SMC readings do not work on your macOS version, enable demo mode in Settings
or from the menu bar. Demo mode generates realistic synthetic data so the UI,
charts, and risk model can still be explored.

## Dust-Risk Model

The current model is no longer based on a user-selected "baseline window".
Instead, it tries to learn the best stable cooling capacity it has observed in
historical raw samples, then compares the recent window against that reference.

At a high level:

1. Samples are grouped by similar workload. CPU and GPU are analyzed separately.
2. For each load bucket, the model keeps a robust low-temperature stable slice
   as the best observed cooling reference.
3. When idle samples are available, it compares temperature rise above idle
   rather than absolute temperature. This helps reduce false positives from room
   temperature changes.
4. It uses a Mann-Whitney U test to compare recent and reference distributions.
5. Fan RPM at the same load is used as supporting evidence.
6. A cleaning recommendation requires enough reference data and corroboration
   across multiple recent days or multiple load buckets.

The Overview risk levels are intentionally conservative:

- **Insufficient data** means DustWatch needs more history. Keep the app running
  in the background; sampling is lightweight.
- **None** means no statistically meaningful cooling-capacity drop was found.
- **Minor / elevated** means the model sees a signal, but not enough
  corroboration for a cleaning recommendation.
- **Needs cleaning** means the model found a stronger, repeated signal versus
  the best cooling reference.

The risk banner includes an explanation popover, so the app can show why it
thinks the current state is safe or risky instead of only showing a color.

![Dust-risk explanation popover for a no-risk state](<screenshots/2-1. dashboard-overview-expanded-detail-explaining-why-there-is-no-risk.png>)

Synthetic demo data can also be used to inspect the high-risk path without
waiting for a real machine to degrade.

![Demo data showing a cleaning recommendation and supporting evidence](<screenshots/3-1. demo-data-overview-expanded-with-risk.png>)

This algorithm is experimental. It can still be confused by major ambient
temperature changes, unusual workloads, bad or missing sensors, cooling-pad
changes, firmware behavior, and short histories. Good future work includes
better ambient estimation, model confidence reporting, larger real-world test
datasets, and machine-specific tuning.

## Data and Privacy

All data stays local. DustWatch has no telemetry service.

Database path:

```sh
~/Library/Application Support/DustWatch/data.db
```

It is a SQLite database:

| Table | Purpose | Retention |
| --- | --- | --- |
| `samples` | Raw sensor readings | About one year plus the recent window |
| `samples_hourly` | Hourly rollups | Up to one year |
| `samples_daily` | Daily rollups | Kept indefinitely |
| `alerts` | Local notification throttle history | Kept indefinitely |
| `config` | User settings | Single row |

Inspect recent rows:

```sh
sqlite3 ~/Library/Application\ Support/DustWatch/data.db \
  "SELECT datetime(ts, 'unixepoch'), cpu_temp, gpu_temp, fan_max FROM samples ORDER BY ts DESC LIMIT 10;"
```

## Build From Source

```sh
git clone https://github.com/NormanZyq/dust-watch-mac.git
cd dust-watch-mac
./build.sh
cp -R build/DustWatch.app /Applications/
```

Useful commands:

```sh
swift test
./build.sh debug
./build.sh clean
./build.sh --arch arm64
./build.sh --arch x86_64
```

`build.sh` compiles the Swift package, assembles `DustWatch.app`, copies the
Info.plist, localized resources, icon, entitlements, and ad-hoc signs the app.

## Project Layout

```text
Sources/
  App/             App entry point and AppDelegate
  SMC/             SMC and system sensor reading
  Sampler/         Periodic sampling loop
  Storage/         SQLite schema, queries, rollups, migrations
  Analysis/        Cooling-reference and dust-risk logic
  Notifications/   Local notification wrapper
  UI/              Menu bar, dashboard, charts, settings
  Resources/       Info.plist, entitlements, icons, localization
Tests/             XCTest coverage for migrations and risk logic
build.sh           SwiftPM build, app bundle assembly, ad-hoc signing
```

## Releases

Pushing a `v*` tag runs the GitHub Actions release workflow. It builds arm64 and
x86_64 DMGs and publishes a GitHub Release with generated release notes. `v0.*`
tags are marked as prereleases; `v1.*` and later are published as stable
releases.

```sh
git tag -a v0.x.y -m "v0.x.y"
git push origin main v0.x.y
```

## Contributing

The most valuable contributions right now are practical validation and model
improvements:

- Real-world cases where the risk level is wrong
- Ideas for distinguishing dust from ambient temperature or workload changes
- Better test fixtures and simulations
- Sensor decoding fixes for specific macOS or hardware versions
- UI improvements that make the risk explanation clearer

Please include the macOS version, Mac model, whether the machine was recently
cleaned, and enough workload context to make thermal changes interpretable.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgements

The SMC reading layer follows the same general community-documented approach as
SMCKit and the smcFanControl family of tools. Apple does not provide a stable
public SMC API for this use case, so this area may need ongoing maintenance.
