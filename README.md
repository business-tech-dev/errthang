# errthang
A macOS native ultra-fast file search utility with real-time indexing and minimal system resource usage heavily inspired by voidtools' Everything.

## Features
- **Ultra-fast file search**: Near instant search results across millions of files using **Zero-Copy Binary Indexing** and **C-optimized scanning**.
- **True UI Virtualization**: Renders lists of 1M+ items quickly with minimal memory footprint.
- **Real-time file indexing**: Uses `FSEvents` to track file system changes without polling.
- **SMB/network share support**: For searching across network volumes.
- **Minimal resource consumption**: "Lazy Materialization" ensures objects are only created when displayed.
- **Scheduled indexing**: Keeps the persistent store up-to-date.
- **Modern macOS UI**: Built with SwiftUI + AppKit for maximum performance.

## TODO
- **Service - The service does not currently seem to work in the background.**

- **Mounts:** 
- **After adding a mounted drive, if the drive goes offline, errthang won't "reveal in finder" again.**
- **Copy Path/Copy Name also do not work.**

## Core Components
- **CSearch**: C module for high-performance raw memory scanning.
- **FileMonitor**: Tracks file system changes using `FSEvents`
- **FileIndexer**: Handles initial crawling and batch indexing with `NSManagedObjectContext` background performance
- **SMBManager**: Manages network volume connections using `NetFS`
- **PersistenceController**: Manages Core Data storage with `sqlite3`

## Building and Running
1. Ensure you have Xcode installed or the Swift toolchain.
2. Run `swift build` to compile the project.
3. Run `swift run` to start the application (or open via Xcode).

## Usage
- **Indexing**: Open Settings (⌘,) -> General and click "Re-Index Home" to start the initial crawl.
- **Search**: Type in the search bar to filter files instantly by name.
- **SMB**: Open Settings (⌘,) -> Network to connect to and index network shares.
