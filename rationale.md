# Performance Optimization Rationale

## Baseline and Problem
When opening a PDF document in Lector, `AppState.openDocument(at:)` synchronously calculates a SHA-256 checksum of the file before proceeding with the rest of the open operations. The checksum requires reading the entire file contents and computing the hash on the main thread.

For small PDFs, this delay is minimal, but for larger PDFs (e.g., academic papers >50MB or books >100MB), the I/O read and CPU-intensive hash computation blocks the main thread, causing a noticeable UI freeze during document loading.

## Impracticality of Direct Measurement
Because the development environment is a Linux container and Lector is a native macOS application requiring `Swift`, `PDFKit`, and `AppKit` (as specified in `README.md`), `xcodebuild` and even the `swift` compiler are unavailable here. Thus, standard profiling (e.g., Instruments or XCTest performance tests) cannot be executed in this container to provide an exact benchmark.

## Optimized Solution
By moving the `Checksum.sha256(of:)` call and the subsequent `database.upsertDocument(url:checksum:)` query to a background queue (e.g., `DispatchQueue.global(qos: .userInitiated)`), we completely remove the blocking work from the main thread. Once the checksum and database operations are finished, we dispatch back to the main thread (`DispatchQueue.main.async`) to update the UI state variables (`documentID`, `currentPage`, etc.) and load annotations.

This leads to a guaranteed and tangible improvement in responsiveness when opening documents, as the UI is immediately returned to the user while the heavy lifting happens asynchronously.
