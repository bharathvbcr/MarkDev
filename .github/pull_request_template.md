## Description

<!-- Provide a clear, concise summary of the changes introduced by this PR. -->

## Related Issue

<!-- Fixes #123 / Closes #456 (if applicable) -->

## Architectural Impact & Invariants

- [ ] Does this change cross the Rust/Swift FFI boundary? If so, are all offsets UTF-16 code units?
- [ ] Are syntax markers derived structurally rather than with ad-hoc regex/string matching?
- [ ] Are collapsed markers styled at 0.01pt in `NSTextStorage` without text deletion?
- [ ] Are layouts modeled as pure value types (`SplitLayout`)?
- [ ] Does this avoid any remote network image/script fetching?

## Testing & Verification

- [ ] Rust tests pass (`cd core && cargo test`)
- [ ] Property tests pass if modifying incremental parser (`cd core && cargo test --test incremental`)
- [ ] Rust performance gate verified in release mode (`cd core && cargo test --release --test performance`)
- [ ] Swift unit & performance tests pass (`just test-app`)
- [ ] Formatted & linted with `just check`

## Screenshots / Screen Recordings (if UI changes are included)

<!-- Attach before/after screenshots or screencasts if applicable. -->
