# Project Restrictions and Avoided Patterns

This document tracks APIs, patterns, and commands that have caused build errors or runtime issues in this project.

## Swift Concurrency & Sendability

### 1. `FileManager` is not Sendable
- **Issue**: `FileManager` class is not thread-safe (`Sendable`).
- **Restriction**: Do not capture `FileManager.default` or other instances in `@Sendable` closures (e.g., `Task`, `context.perform`).
- **Solution**: Create local instances of `FileManager` inside the async context or actor method.

### 2. `ByteCountFormatter` / `DateFormatter`
- **Issue**: Formatters are not `Sendable`.
- **Restriction**: Do not use global static instances across concurrency domains without isolation.
- **Solution**: Annotate shared instances with `@MainActor` or create local instances.

### 3. Asynchronous Iteration over `FileManager.DirectoryEnumerator`
- **Issue**: `for case let url as URL in enumerator` uses `makeIterator()`, which is unavailable in asynchronous contexts.
- **Restriction**: Do not use `for-in` loops with `enumerator` inside `async` functions or actors.
- **Solution**: Use `while let url = enumerator.nextObject() as? URL`.

## Deprecated APIs

### 1. FSEvents RunLoop Scheduling
- **Issue**: `FSEventStreamScheduleWithRunLoop` is deprecated in macOS 13+.
- **Restriction**: Do not use RunLoop scheduling for FSEvents.
- **Solution**: Use `FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)` (or another queue).

### 2. SwiftUI `onChange(of:perform:)`
- **Issue**: The single-parameter closure version is deprecated.
- **Restriction**: Do not use `.onChange(of: value) { newValue in ... }`.
- **Solution**: Use the two-parameter closure: `.onChange(of: value) { oldValue, newValue in ... }`.

## Tooling & Workflow

### 1. File Modification
- **Issue**: `write_to_file` tool fails if the target file exists.
- **Restriction**: Do not use `write_to_file` to overwrite.
- **Solution**: Use `edit` or `multi_edit` for existing files.

### 2. Parallel File Operations
- **Issue**: Deleting and writing the same file path in parallel tool calls causes race conditions.
- **Restriction**: Do not batch `run_command(rm ...)` and `write_to_file(...)` for the same file.
- **Solution**: Execute them in sequential turns.

## Core Data & Persistence

### 1. Resource Bundling for Executables
- **Issue**: `Bundle.module` fails to locate `.momd` / `.mom` files when running as a Swift Package Executable (CLI/App).
- **Restriction**: Avoid relying on `NSManagedObjectModel(contentsOf:)` with bundled resources for single-package executables.
- **Solution**: Define the `NSManagedObjectModel` programmatically using `NSEntityDescription` and `NSAttributeDescription`.

### 2. Deprecated `isIndexed`
- **Issue**: `NSAttributeDescription.isIndexed` is deprecated in macOS 10.13+.
- **Restriction**: Do not use `attribute.isIndexed = true`.
- **Solution**: Use `NSEntityDescription.indexes` with `NSFetchIndexDescription` elements instead.

## File System & Paths

### 1. Path Canonicalization on macOS
- **Issue**: macOS `/var` is a symlink to `/private/var`. `FileManager.enumerator` returns canonical paths (`/private/var/...`), but `URL(fileURLWithPath:)` with standard resolution might return the symlinked path (`/var/...`) or vice versa depending on existence.
- **Restriction**: Do not rely on raw paths for Core Data keys.
- **Solution**: Always use `URL.resolvingSymlinksInPath()` or `resourceValues(forKeys: [.canonicalPathKey])` to normalize paths before storing or querying. When a file is missing (for deletion), resolve the parent directory's canonical path and append the filename.
