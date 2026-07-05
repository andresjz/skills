---
name: release
description: Create semantic version releases with auto-generated changelogs based on conventional commits
compatibility: Requires git. Optional: gh CLI for GitHub releases
metadata:
  version: "1.0.0"
---

# Create Release

## Purpose
Create semantic version releases by analyzing commit history, determining the next version, generating changelogs, and creating git tags. Optionally publish releases to GitHub.

## Prerequisites
- Git repository with commit history
- `gh` CLI authenticated (optional, for GitHub releases)

## Execution mode

This skill runs in **two modes**:

- **Interactive mode**: Ask user for confirmation before creating tag/release
- **CI mode**: Run non-interactively with `CI=true` environment variable

## Required workflow

### 1. Validate repository state

```bash
# Check we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "❌ Not a git repository"
  exit 1
fi

# Check working tree is clean (interactive mode only)
if [ -z "$CI" ]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "⚠️  Working tree has uncommitted changes"
    echo "Continue anyway? (y/N): "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      echo "Aborted"
      exit 0
    fi
  fi
fi
```

### 2. Get current version

```bash
# Get the latest tag
LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [ -n "$LATEST_TAG" ]; then
  echo "🏷️  Current version: $LATEST_TAG"
  
  # Extract version components
  VERSION=${LATEST_TAG#v}
  CURRENT_MAJOR=$(echo $VERSION | cut -d. -f1)
  CURRENT_MINOR=$(echo $VERSION | cut -d. -f2)
  CURRENT_PATCH=$(echo $VERSION | cut -d. -f3)
else
  echo "🆕 No previous version found (will create v1.0.0)"
  CURRENT_MAJOR=0
  CURRENT_MINOR=0
  CURRENT_PATCH=0
fi
```

### 3. Analyze commits and determine version bump

```bash
# Get commits since last tag
if [ -n "$LATEST_TAG" ]; then
  COMMITS=$(git log "${LATEST_TAG}..HEAD" --pretty=format:"%s" --no-merges)
  COMMITS_COUNT=$(git rev-list --count "${LATEST_TAG}..HEAD")
else
  COMMITS=$(git log --pretty=format:"%s" --no-merges)
  COMMITS_COUNT=$(git rev-list --count HEAD)
fi

echo "📊 Analyzing ${COMMITS_COUNT} commits..."

# Auto-detect version bump from conventional commits
AUTO_BUMP="patch"  # default

# Check for breaking changes
if echo "$COMMITS" | grep -qE '^(BREAKING CHANGE:|.*!:)'; then
  AUTO_BUMP="major"
  echo "🔍 Detected: BREAKING CHANGE → major bump"
# Check for features
elif echo "$COMMITS" | grep -qE '^(feat|feature):'; then
  AUTO_BUMP="minor"
  echo "🔍 Detected: feat/feature → minor bump"
# Check for fixes
elif echo "$COMMITS" | grep -qE '^(fix|bugfix|perf|refactor):'; then
  AUTO_BUMP="patch"
  echo "🔍 Detected: fix/bugfix/perf/refactor → patch bump"
fi
```

### 4. Ask for version type (interactive mode)

**Interactive mode:**

```bash
echo ""
echo "Version bump options:"
echo "  1) major (${CURRENT_MAJOR}.$((CURRENT_MINOR)).$((CURRENT_PATCH)) → $((CURRENT_MAJOR + 1)).0.0)"
echo "  2) minor (${CURRENT_MAJOR}.${CURRENT_MINOR}.${CURRENT_PATCH} → ${CURRENT_MAJOR}.$((CURRENT_MINOR + 1)).0)"
echo "  3) patch (${CURRENT_MAJOR}.${CURRENT_MINOR}.${CURRENT_PATCH} → ${CURRENT_MAJOR}.${CURRENT_MINOR}.$((CURRENT_PATCH + 1)))"
echo "  4) auto  (detected: ${AUTO_BUMP})"
echo ""
read -p "Choose version bump [default: 4]: " choice

case ${choice:-4} in
  1) VERSION_TYPE="major" ;;
  2) VERSION_TYPE="minor" ;;
  3) VERSION_TYPE="patch" ;;
  4|") VERSION_TYPE="$AUTO_BUMP" ;;
  *)
    echo "Invalid choice, using auto"
    VERSION_TYPE="$AUTO_BUMP"
    ;;
esac
```

**CI mode:** Use environment variable or auto-detect

```bash
VERSION_TYPE="${VERSION_BUMP:-$AUTO_BUMP}"
```

### 5. Calculate new version

```bash
case $VERSION_TYPE in
  major)
    NEW_MAJOR=$((CURRENT_MAJOR + 1))
    NEW_MINOR=0
    NEW_PATCH=0
    ;;
  minor)
    NEW_MAJOR=$CURRENT_MAJOR
    NEW_MINOR=$((CURRENT_MINOR + 1))
    NEW_PATCH=0
    ;;
  patch)
    NEW_MAJOR=$CURRENT_MAJOR
    NEW_MINOR=$CURRENT_MINOR
    NEW_PATCH=$((CURRENT_PATCH + 1))
    ;;
  *)
    echo "❌ Invalid version type: $VERSION_TYPE"
    exit 1
    ;;
esac

NEW_VERSION="${NEW_MAJOR}.${NEW_MINOR}.${NEW_PATCH}"
TAG_NAME="v${NEW_VERSION}"

echo ""
echo "📈 New version: $TAG_NAME ($VERSION_TYPE bump)"
```

### 6. Check if tag already exists

```bash
if git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null 2>&1; then
  echo "❌ Tag $TAG_NAME already exists"
  echo "Use a different version or delete the existing tag"
  exit 1
fi

echo "✅ Tag $TAG_NAME is available"
```

### 7. Generate changelog

```bash
# Categorize commits
BREAKING=$(echo "$COMMITS" | grep -E '^(BREAKING CHANGE:|.*!:)' || true)
FEATURES=$(echo "$COMMITS" | grep -E '^(feat|feature):' || true)
FIXES=$(echo "$COMMITS" | grep -E '^(fix|bugfix):' || true)
PERF=$(echo "$COMMITS" | grep -E '^(perf|refactor):' || true)
DOCS=$(echo "$COMMITS" | grep -E '^(docs|doc):' || true)
OTHER=$(echo "$COMMITS" | grep -vE '^(BREAKING CHANGE:|.*!:|feat|feature|fix|bugfix|perf|refactor|docs|doc):' || true)

# Generate changelog
cat > /tmp/release_changelog.md << EOF
## 🚀 Release ${TAG_NAME}

**Date:** $(date +%Y-%m-%d)
**Commits:** ${COMMITS_COUNT}
EOF

if [ -n "$LATEST_TAG" ]; then
  echo "**Since:** ${LATEST_TAG}" >> /tmp/release_changelog.md
else
  echo "**Note:** *First release*" >> /tmp/release_changelog.md
fi

echo "" >> /tmp/release_changelog.md

if [ -n "$BREAKING" ]; then
  {
    echo "### ⚠️ Breaking Changes"
    echo "$BREAKING" | sed 's/^/- /'
    echo ""
  } >> /tmp/release_changelog.md
fi

if [ -n "$FEATURES" ]; then
  {
    echo "### ✨ Features"
    echo "$FEATURES" | sed 's/^/- /'
    echo ""
  } >> /tmp/release_changelog.md
fi

if [ -n "$FIXES" ]; then
  {
    echo "### 🐛 Bug Fixes"
    echo "$FIXES" | sed 's/^/- /'
    echo ""
  } >> /tmp/release_changelog.md
fi

if [ -n "$PERF" ]; then
  {
    echo "### ⚡ Performance & Refactoring"
    echo "$PERF" | sed 's/^/- /'
    echo ""
  } >> /tmp/release_changelog.md
fi

if [ -n "$DOCS" ]; then
  {
    echo "### 📚 Documentation"
    echo "$DOCS" | sed 's/^/- /'
    echo ""
  } >> /tmp/release_changelog.md
fi

if [ -n "$OTHER" ]; then
  {
    echo "### 📝 Other Changes"
    echo "$OTHER" | sed 's/^/- /'
    echo ""
  } >> /tmp/release_changelog.md
fi

# Add full changelog
{
  echo "### 📋 Full Changelog"
  if [ -n "$LATEST_TAG" ]; then
    git log "${LATEST_TAG}..HEAD" --pretty=format:"- %s (\`%h\`) by %an" --no-merges
  else
    git log --pretty=format:"- %s (\`%h\`) by %an" --no-merges -50
  fi
  echo ""
} >> /tmp/release_changelog.md

echo "✅ Changelog generated"
```

### 8. Show changelog preview (interactive mode)

```bash
if [ -z "$CI" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  cat /tmp/release_changelog.md
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  read -p "Create tag $TAG_NAME? (Y/n): " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo "Aborted"
    rm /tmp/release_changelog.md
    exit 0
  fi
fi
```

### 9. Create git tag

```bash
# Configure git user if not set
if [ -z "$(git config user.name)" ]; then
  git config user.name "release-script"
  git config user.email "release@localhost"
fi

# Create annotated tag
git tag -a "${TAG_NAME}" -m "Release ${TAG_NAME}"

echo "🏷️  Tag $TAG_NAME created"
```

### 10. Push tag (optional)

**Interactive mode:**
```bash
read -p "Push tag to remote? (Y/n): " push_confirm
if [[ ! "$push_confirm" =~ ^[Nn]$ ]]; then
  git push origin "${TAG_NAME}"
  echo "📤 Tag pushed to remote"
fi
```

**CI mode:**
```bash
if [ "${PUSH_TAG:-true}" = "true" ]; then
  git push origin "${TAG_NAME}"
  echo "📤 Tag pushed to remote"
fi
```

### 11. Create GitHub release (optional)

```bash
if command -v gh &> /dev/null && gh auth status &> /dev/null; then
  if [ -z "$CI" ]; then
    read -p "Create GitHub release? (Y/n): " gh_confirm
    if [[ "$gh_confirm" =~ ^[Nn]$ ]]; then
      echo "Skipping GitHub release"
      rm /tmp/release_changelog.md
      exit 0
    fi
  fi
  
  # Create release
  gh release create "${TAG_NAME}" \
    --title "Release ${TAG_NAME}" \
    --notes-file /tmp/release_changelog.md
  
  echo "🎉 GitHub release created"
else
  echo "ℹ️  gh CLI not available or not authenticated, skipping GitHub release"
fi
```

### 12. Cleanup and summary

```bash
rm /tmp/release_changelog.md

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Release complete!"
echo ""
echo "Version: $TAG_NAME"
echo "Type:    $VERSION_TYPE bump"
echo "Commits: $COMMITS_COUNT"
echo ""
echo "Next steps:"
echo "  • View tags:    git tag -l"
echo "  • Push tag:     git push origin $TAG_NAME"
echo "  • View release: git show $TAG_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

## Usage examples

**Interactive:**
```bash
# Run the skill and follow prompts
/release
```

**CI mode (non-interactive):**
```bash
# Auto-detect version and push
CI=true PUSH_TAG=true /release

# Force specific version bump
CI=true VERSION_BUMP=major /release
```

**Manual version override:**
```bash
# When prompted, choose option 1-4 or specify VERSION_BUMP env var
VERSION_BUMP=minor /release
```

## Output

The skill creates:
- Git annotated tag with release message
- Auto-generated changelog categorized by commit type
- Optional GitHub release with formatted notes

## Commit message conventions

The auto-detection works best with conventional commits:

- `feat:` or `feature:` → minor version bump
- `fix:` or `bugfix:` → patch version bump
- `perf:` or `refactor:` → patch version bump
- `docs:` → patch version bump
- `BREAKING CHANGE:` or `!:` → major version bump

Examples:
```
feat: add new user authentication
fix: resolve memory leak in cache
docs: update API documentation
feat!: change authentication API (BREAKING CHANGE)
```
