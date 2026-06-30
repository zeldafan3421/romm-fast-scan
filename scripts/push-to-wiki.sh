#!/bin/sh
# push-to-wiki.sh — Push documentation to GitHub Wiki
# ─────────────────────────────────────────────────────────────────────────────
#
# This script:
#   1. Clones the GitHub Wiki repo (if not already cloned)
#   2. Copies docs to wiki-format
#   3. Creates sidebar navigation
#   4. Pushes everything to the wiki
#
# Usage:
#   sh scripts/push-to-wiki.sh
#
# Prerequisites:
#   - You have push access to the repo (and its wiki)
#   - git is configured with credentials
#   - The repo is on GitHub

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WIKI_DIR="$(mktemp -d)/wiki"

# Extract repo info from git
REPO_URL=$(cd "$REPO_ROOT" && git config --get remote.origin.url)
WIKI_URL="${REPO_URL%.git}.wiki.git"
WIKI_DIR_NAME=$(basename "$WIKI_URL" .wiki.git).wiki

echo "=== Pushing docs to GitHub Wiki ==="
echo ""
echo "Repo URL: $REPO_URL"
echo "Wiki URL: $WIKI_URL"
echo "Working directory: $WIKI_DIR"
echo ""

# Clone the wiki repo
echo "Cloning wiki repo..."
if git clone "$WIKI_URL" "$WIKI_DIR" 2>/dev/null; then
    echo "✓ Cloned existing wiki"
else
    echo "Note: Wiki repo doesn't exist yet. Creating local copy..."
    mkdir -p "$WIKI_DIR"
    cd "$WIKI_DIR"
    git init
    git config user.name "Wiki Bot"
    git config user.email "noreply@github.com"
fi

cd "$WIKI_DIR"

# Remove old docs
echo "Clearing old documentation..."
find . -name "*.md" -not -name "Home.md" -not -name "_*" -delete

# Copy docs (converting names to wiki format)
echo "Copying documentation to wiki..."
cd "$REPO_ROOT/docs"

# Home page
cp BUILD_QUICK_START.md "$WIKI_DIR/Home.md"
sed -i '1s/^/# Quick Start\n\n/' "$WIKI_DIR/Home.md"

# Copy other docs with wiki-friendly names
cp TESTING.md "$WIKI_DIR/Testing.md"
cp EDGE_CASES.md "$WIKI_DIR/Edge-Cases.md"
cp TROUBLESHOOTING.md "$WIKI_DIR/Troubleshooting.md"
cp ARCHITECTURE.md "$WIKI_DIR/Architecture.md"
cp PRE_DEPLOYMENT_CHECKLIST.md "$WIKI_DIR/Pre-Deployment-Checklist.md"
cp CONTAINER_BUILD.md "$WIKI_DIR/Container-Build.md"
cp CONTAINER_SUMMARY.md "$WIKI_DIR/Container-Design.md"
cp DOCUMENTATION_SUMMARY.md "$WIKI_DIR/Documentation-Index.md"

# Create sidebar (wiki navigation)
cat > "$WIKI_DIR/_Sidebar.md" << 'SIDEBAR'
## Documentation

- **[Home](Home)** — Quick start and overview
- **[Testing](Testing)** — Manual and automated tests
- **[Pre-Deployment Checklist](Pre-Deployment-Checklist)** — Readiness checklist
- **[Troubleshooting](Troubleshooting)** — Common issues and solutions
- **[Edge Cases](Edge-Cases)** — Limitations and workarounds
- **[Architecture](Architecture)** — Technical internals
- **[Container Build](Container-Build)** — Building container images
- **[Container Design](Container-Design)** — Design decisions
- **[Documentation Index](Documentation-Index)** — Meta-documentation

## Getting Started

1. Visit the [main repository](https://github.com/zeldafan3421/romm-fast-scan)
2. Read [README.md](https://github.com/zeldafan3421/romm-fast-scan/blob/main/README.md)
3. Run `sh scripts/install.sh` to deploy
4. Check [Pre-Deployment Checklist](Pre-Deployment-Checklist) before production use
SIDEBAR

# Create Footer (optional, wiki navigation)
cat > "$WIKI_DIR/_Footer.md" << 'FOOTER'
---
[← Back to Repository](https://github.com/zeldafan3421/romm-fast-scan)
FOOTER

echo "✓ Copied all documentation to wiki format"
echo ""
echo "=== Committing wiki changes ==="
cd "$WIKI_DIR"
git add -A
git commit -m "Add romm-fast-scan documentation

Migrated documentation from repository to GitHub Wiki:
- Home: Quick start guide
- Testing: Test procedures and benchmarks
- Edge Cases: Limitations and edge cases
- Troubleshooting: Common issues and solutions
- Architecture: Technical internals and design
- Pre-Deployment Checklist: Production readiness
- Container Build: Building container images
- Container Design: Design decisions and maintenance
- Documentation Index: Meta-documentation

Wiki includes automatic navigation via _Sidebar.md"

echo "✓ Committed changes"
echo ""
echo "=== Pushing to GitHub Wiki ==="
git push -u origin master 2>/dev/null || git push -u origin main 2>/dev/null || {
    echo "✗ Push failed. Try pushing manually:"
    echo "  cd $WIKI_DIR"
    echo "  git push -u origin master"
    exit 1
}

echo "✓ Pushed to wiki"
echo ""
echo "=== Success ==="
echo ""
echo "Documentation is now available at:"
echo "  https://github.com/zeldafan3421/romm-fast-scan/wiki"
echo ""
echo "Next steps:"
echo "  1. Visit the wiki and verify all pages are there"
echo "  2. You can now remove docs/ from the main repo:"
echo "       git rm -r docs/"
echo "       git commit -m 'Remove docs (migrated to wiki)'"
echo "       git push"
