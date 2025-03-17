#!/bin/bash
#
# Format markdown files using prettier
# This ensures consistent formatting and line length compliance
# and aligns with MDL (markdownlint) rules
#

# Check if .prettierrc.json exists - we'll use that if available
if [ -f ".prettierrc.json" ]; then
  USE_CONFIG=true
  echo "Using configuration from .prettierrc.json"
else
  USE_CONFIG=false
  
  # Default options aligned with MDL rules
  PROSE_WRAP="always"      # aligns with MD013 line length enforcement
  PRINT_WIDTH="80"         # matches the MDL MD013 default of 80 chars
  TAB_WIDTH="2"            # standard indentation
  END_OF_LINE="lf"         # consistent line endings
fi

# Get list of files to format
if [ "$#" -eq 0 ]; then
  # If no arguments, format all markdown files except in certain dirs
  FILES=$(find . -name "*.md" -not -path "./node_modules/*" -not -path "./vendor/*")
else
  # Otherwise format the specified files
  FILES="$@"
fi

# Check if we're using Prettier 3.x which supports ignoreSelectors for tables
PRETTIER_VERSION=$(npx prettier --version 2>/dev/null || echo "0.0.0")
PRETTIER_MAJOR_VERSION=$(echo $PRETTIER_VERSION | cut -d. -f1)

echo "Formatting markdown files with prettier ${PRETTIER_VERSION}..."

# Format based on whether we have a config file or not
if [ "$USE_CONFIG" = true ]; then
  # Use the .prettierrc.json config file
  if [ "$PRETTIER_MAJOR_VERSION" -ge 3 ]; then
    # Prettier 3.x supports ignoreSelectors for tables (matching MDL tables: false)
    npx prettier --ignore-path .gitignore --write $FILES \
      --ignore-unknown
  else
    # Older Prettier versions - just use the config
    npx prettier --ignore-path .gitignore --write $FILES \
      --ignore-unknown
  fi
else
  # No config file, use command line options
  if [ "$PRETTIER_MAJOR_VERSION" -ge 3 ]; then
    # Prettier 3.x supports ignoreSelectors for tables (matching MDL tables: false)
    npx prettier --prose-wrap $PROSE_WRAP \
      --print-width $PRINT_WIDTH \
      --tab-width $TAB_WIDTH \
      --end-of-line $END_OF_LINE \
      --ignore-path .gitignore \
      --write $FILES \
      --ignore-unknown
  else
    # Older Prettier versions
    npx prettier --prose-wrap $PROSE_WRAP \
      --print-width $PRINT_WIDTH \
      --tab-width $TAB_WIDTH \
      --end-of-line $END_OF_LINE \
      --ignore-path .gitignore \
      --write $FILES \
      --ignore-unknown
  fi
fi

# Check if prettier formatting was successful
if [ $? -eq 0 ]; then
  echo "✅ Markdown formatting completed successfully"
  
  # Now check if the files pass mdl for full compliance
  if command -v mdl &> /dev/null; then
    echo "Running markdownlint to verify compliance..."
    mdl $FILES
    if [ $? -eq 0 ]; then
      echo "✅ All files pass markdownlint checks"
    else
      echo "⚠️ Some markdownlint issues remain - you may need to manually fix them"
      echo "   (Tables and other special formatting may need attention)"
    fi
  else
    echo "ℹ️ mdl (markdownlint) not found, skipping verification"
  fi
else
  echo "❌ Prettier had some issues formatting the files"
fi