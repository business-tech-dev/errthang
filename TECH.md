# Technical Architecture & Performance

## Core Architecture
- **SearchService (Actor)**: The central source of truth. Manages the hybrid index (Static Binary + Live Deltas), handles search queries, and coordinates data loading.
- **CSearch**: A high-performance C module that handles the raw memory scanning of the binary index using `memmem` and SIMD-optimized instructions.
- **BinaryIndex**: A custom memory-mapped (mmap) binary file reader that allows searching and accessing 750k+ items with zero heap allocation.
- **FileMonitor**: Uses `FSEvents` to track file system changes in real-time. Live updates are stored in a "Delta Map" overlaying the static binary index.
- **Persistence**: Core Data (`sqlite3`) is used as the durable source of truth, from which the optimized `index.bin` is generated.
- **UI**: SwiftUI for the application shell, with AppKit (`NSTableView`) for the high-performance results list, utilizing true data virtualization.

## Performance Strategies
### 1. Zero-Copy Binary Indexing
- **C-Powered Scanning**: The hot loop of the search engine is implemented in pure C (`CSearch`). It scans the memory-mapped file directly using `memmem`, avoiding Swift ARC overhead and bounds checking.
- **Memory Mapping (`mmap`)**: The application maps a custom `index.bin` file directly into virtual memory. This allows the OS to manage paging, and the app "reads" data without copying it into the heap.
- **Lazy Materialization**: Search results are passed around as lightweight `Int32` indices. A `SearchResultItem` Swift object is only created ("materialized") when a specific row is about to be rendered on screen.
- **Custom Binary Format (v2)**: We use a custom, compact binary format with 8-byte alignment for 64-bit integers and Doubles, ensuring safe and fast access on ARM64 (Apple Silicon).

### 2. Hybrid Search (Static + Dynamic)
- **Fast Path (Virtual)**: If there are no pending file system changes (Deltas), searches happen purely in the binary domain. The system returns indices directly from the mmap region, avoiding all object overhead.
- **Merge Path (Live)**: When file changes occur, the system transparently merges the static binary results with the live "Delta Map" (additions/modifications) and filters out "Deleted Paths".
- **Auto-Rebuild**: To return to the Fast Path quickly, the binary index is automatically rebuilt from the database 5 seconds after file activity settles.

### 3. True UI Virtualization
- **Virtual Data Source**: The `FastTableView` is no longer backed by an array of objects. It is backed by a `SearchResults` collection that holds `Int32` pointers.
- **On-Demand Loading**: `NSTableView` asks for the object at row X. Only then does the `BinaryIndex` read the bytes at the corresponding offset, decode the UTF-8 strings, and return a struct.
- **Result**: We can "load" and scroll 1 million results nearly instantly because we only ever pay the deserialization cost for the ~20 visible rows.

## UI Optimizations

### Hybrid SwiftUI + AppKit
#### `FastTableView`
We implemented a custom `NSViewRepresentable` wrapper around AppKit's `NSTableView` to handle the results list.
- **Cell Reuse**: `NSTableView` only allocates views for currently visible rows.
- **Zero Diffing Overhead**: We bypass SwiftUI's state diffing. When search results change, we swap the virtual collection reference and call `reloadData()`.
- **Performance**: Capable of scrolling and rendering 1M+ rows at 60fps with minimal memory footprint.

### Efficient State Management
- **Versioning Strategy**: The table view observes a `searchResultsVersion` UUID to trigger updates only when necessary.
- **Debouncing**: Search input is debounced to prevent unnecessary query thrashing.
- **Main Thread Concurrency**: UI coordinators are isolated to `@MainActor`.

## Database Optimization
- **Binary Sorting**: Database fetches use `NSSortDescriptor` with binary comparison for speed.
- **Background Context**: Index rebuilding occurs on a background `NSManagedObjectContext`, keeping the UI responsive.
