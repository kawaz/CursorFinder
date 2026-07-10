# LaserGuide v3 — AI Assistant Guide

> [日本語](./CLAUDE.ja.md)

macOS menu-bar app that visualizes "where am I now?" on multi-monitor setups via overlay rendering.
Three components: **Laser** (cursor location) / **Edge Warp** (cursor movement control at virtual boundaries) / **Focus Flash** (highlights the monitor that received window focus).

## Branch status (important)

- **v3 (this branch)**: full rewrite on SPM. The active line of development
- main: v0.12.1 distribution line (v1 implementation). **Pushing to main triggers the release CD** — do not touch until v3 replaces it
- v2: local-only previous rewrite skeleton (v3 branched from it). `LaserGuide/` and `LaserGuide.v1.backup/` are previous-generation sources kept for reference — read them, never modify

## Quick Commands

```bash
just ci          # lint (swiftlint --strict) + all Core/App tests
just test        # tests only
just run         # dev run (swift run laserguide-dev); needs Accessibility permission
just build-app   # assemble LaserGuide.app (ad-hoc signed + verified)
just push-wip    # push current branch with ci gate (main is rejected)
```

## Architecture

- `Core/` — **UI-independent pure-function layer** (SwiftPM): coordinate types, pose, edge connections, warp judgement, reducer, persistence schema. Tests are the spec (read the intent comments)
- `App/` — executable `laserguide-dev` (SwiftPM): effect interpreter (CGEventTap / overlays / UserDefaults / WKWebView bridge) and menu bar
- Unidirectional data flow (hand-rolled Elm-style, DR-0004): `reduce(AppState, Action) -> (AppState, [Effect])`. No side effects in the reducer; single store, synchronous on the main run loop
- `App/Resources/calibration/` — calibration UI (a **pure view** in WKWebView; implementing geometry in JS is forbidden = DR-0008)

## Coordinate-system iron rules (DR-0005)

- Logical coordinates = **CG global (top-left origin, y-down)**. `LogicalPoint` / `PhysicalPoint` (mm, also y-down) are separate types
- Values from NSScreen / NSEvent / AX are **converted to CG immediately at the input-adapter boundary**; never carry y-up inside the reducer
- "Top" = the minY side. Real-machine clamp behavior (min side = exact boundary / max side = −0.02px) is recorded in docs/findings/

## Working conventions

- Design decisions live in `docs/decisions/` (DR-0002..0010 + INDEX) — check both directions when implementation and DRs disagree
- History in `docs/journal/`, real-device procedures in `docs/runbooks/v3-dev-run.md`, open tasks in `docs/issue/`
- Never create tags / GH Releases manually (the CD does that). Release timing is kawaz's call
- Tests carry intent comments per spec contour. Loosening tests to get green is forbidden
