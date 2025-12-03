# AI Assistant Guidelines for LaserGuide

LaserGuide: macOS app displaying laser lines from screen corners to mouse cursor.

## Quick Reference

### Testing After Changes
```bash
# LOCAL development (quick iteration)
./scripts/dev-run.sh          # Build and run locally

# BEFORE pushing to main (catches build errors locally)
./scripts/pre-push-test.sh    # Run same build tests as CI

# AFTER push to main
./scripts/verify-ci-cd.sh     # Wait for CI/CD completion and test installation
```

### Development Workflow
- **Direct commits to main**: For simple fixes
- **Feature branches with worktrees**: For complex features only
- **Conventional commits**: `feat:` (minor bump) / `fix:` (patch bump) / `docs:` (no release)
- **Always run pre-push-test.sh**: Before pushing to catch CI failures locally

### Project Structure
- `LaserGuide/` - Swift source code
- `scripts/` - Test automation scripts
- `Casks/` - Homebrew cask template
- `.github/workflows/` - CI/CD automation

## Automated Systems

### CI/CD Pipeline
Push to main → Build/Test → Version bump (if code changed) → Release → Update Homebrew tap

### Release Process
Fully automated. Code changes trigger:
1. Version determination from commit messages
2. Build and create GitHub release
3. Update `kawaz/homebrew-laserguide` repository

## Code Guidelines

### Key Files
- `Managers/MouseTrackingManager.swift` - Mouse event handling (debounce pattern)
- `Models/LaserViewModel.swift` - Laser display logic
- `Config.swift` - App configuration

### Mouse Tracking
- Monitor: `.mouseMoved`, `.leftMouseDragged`, `.rightMouseDragged`, `.otherMouseDragged`
- **Do not** monitor: `.scrollWheel` (prevents inertia scroll issues)
- Use `DispatchWorkItem` for debounce (not `Timer`)

## Documentation Maintenance

### Regular Cleanup Tasks
When starting a new session, check:
1. Remove obsolete files/directories
2. Update outdated documentation
3. Keep CLAUDE.md concise (this file)

### Documentation Files
- `README.md` / `README.ja.md` - User documentation (synced)
- `CONTRIBUTING.md` - Development guide
- `CLAUDE.md` - This file (AI assistant context)
- `.github/workflows/README.md` / `README.ja.md` - CI/CD overview (synced)

### Maintenance Principles
- **Concise over comprehensive**: Remove redundancy
- **Actionable over explanatory**: Focus on what to do
- **Current over complete**: Delete outdated content
- **Automated over manual**: Use scripts for repetitive tasks

## Common Tasks

### Fix and Deploy
1. Make code changes
2. Commit with conventional prefix
3. **Run `./scripts/pre-push-test.sh`** (catches build errors before CI)
4. Push to main
5. Run `./scripts/verify-ci-cd.sh` (includes CI/CD verification and Homebrew installation test)
6. Verify functionality

### Add Feature
1. Create worktree if complex: `git worktree add .worktrees/feature-name -b feature/feature-name`
2. Implement and test locally
3. Commit with `feat:` prefix
4. Merge to main
5. Clean up worktree
6. Follow "Fix and Deploy" steps

## Important Notes
- **Code signing**: Using Apple Development certificate (free)
  - First launch requires: Right-click → Open → Open button
  - For no warnings: Need Developer ID certificate ($99/year)
- **Homebrew tap**: Separate repository `kawaz/homebrew-laserguide`
- **Test scripts**: Use provided scripts to avoid repetitive work
- **Keep this file short**: Remove outdated information regularly