# Canopy

A macOS app store for Northwoods Community Church apps. Discover, install, and update all Northwoods tools from one place.

![Canopy Icon](docs/images/icon.png)

## Features

- Browse all Northwoods apps from the GitHub organization
- One-click install from GitHub releases
- Automatic update checking via Sparkle appcasts
- See which apps are installed and their versions
- Update apps without opening them first
- Search and filter by name or description
- Canopy updates itself via Sparkle

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac

## Installation

1. Download the latest `.zip` from [Releases](https://github.com/NorthwoodsCommunityChurch/Canopy/releases)
2. Extract the zip
3. Move `Canopy.app` to `/Applications`
4. Try to open it (macOS will block it)
5. Go to **System Settings > Privacy & Security** and click **Open Anyway**
6. Canopy will now open normally going forward

## Usage

1. Launch Canopy
2. Browse the **All Apps** tab to see available Northwoods apps
3. Click **Install** to download and install an app to `/Applications`
4. The **Updates** tab shows apps with newer versions available
5. Click **Update** to update an app in place
6. Click **Open** to launch an installed app, or use the dropdown to uninstall

## Building from Source

```bash
# Install xcodegen if needed
brew install xcodegen

# Build
./build.sh
```

The built app will be at `build/Build/Products/Release/Canopy.app`.

## Project Structure

```
Canopy/
├── project.yml                    # XcodeGen configuration
├── build.sh                       # Build, sign, and zip script
├── Resources/
│   ├── Info.plist                 # App metadata + Sparkle config
│   └── Assets.xcassets/           # App icon
└── Sources/Canopy/
    ├── CanopyApp.swift            # App entry point + Sparkle self-updater
    ├── Models/
    │   ├── AppInfo.swift          # App, release, and install state models
    │   └── CanopyError.swift      # Error types
    ├── Services/
    │   ├── GitHubService.swift    # GitHub API for repo/release discovery
    │   ├── AppcastService.swift   # Sparkle appcast XML parser
    │   ├── IconService.swift      # Icon fetching and caching
    │   └── InstallService.swift   # Download, extract, install to /Applications
    ├── ViewModels/
    │   └── CatalogViewModel.swift # Main state management
    └── Views/
        ├── ContentView.swift      # Sidebar + grid layout
        └── AppCardView.swift      # Individual app cards
```

## License

See [LICENSE](LICENSE).

## Credits

See [CREDITS.md](CREDITS.md).
