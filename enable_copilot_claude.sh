#!/bin/bash
# Enable Claude Copilot mode
# This will restore .claude folder and start copilot-api server
# Usage: ./enable_copilot_claude.sh [--free|--pro|--max|--mini]
# Default: --pro

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$PROJECT_ROOT/.claude"
CLAUDE_LOCAL_DIR="$PROJECT_ROOT/.claude_local"
PID_FILE="$PROJECT_ROOT/.copilot_pid"
LOG_FILE="$PROJECT_ROOT/.copilot.log"
SETTINGS_TIER="pro"

# Parse arguments for model tier
for arg in "$@"; do
  case $arg in
    --free)
      SETTINGS_TIER="free"
      shift
      ;;
    --pro)
      SETTINGS_TIER="pro"
      shift
      ;;
    --max)
      SETTINGS_TIER="max"
      shift
      ;;
    --mini)
      SETTINGS_TIER="mini"
      shift
      ;;
  esac
done

echo "🤖 Enabling Claude Copilot mode (tier: $SETTINGS_TIER)..."

# Rename .claude_local back to .claude
if [ -d "$CLAUDE_LOCAL_DIR" ]; then
  if [ -d "$CLAUDE_DIR" ]; then
    echo "⚠️  Warning: Both .claude and .claude_local exist. Removing .claude first..."
    rm -rf "$CLAUDE_DIR"
  fi
  mv "$CLAUDE_LOCAL_DIR" "$CLAUDE_DIR"
  echo "✅ Restored .claude folder"
else
  if [ -d "$CLAUDE_DIR" ]; then
    echo "✅ .claude folder already exists"
  else
    echo "❌ Error: Neither .claude nor .claude_local found!"
    exit 1
  fi
fi

# Copy the appropriate settings template to settings.json
SETTINGS_TEMPLATE="$CLAUDE_DIR/settings-${SETTINGS_TIER}.json"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

if [ -f "$SETTINGS_TEMPLATE" ]; then
  cp "$SETTINGS_TEMPLATE" "$SETTINGS_FILE"
  echo "✅ Loaded settings from settings-${SETTINGS_TIER}.json"
else
  echo "⚠️  Warning: settings-${SETTINGS_TIER}.json not found, using existing settings.json"
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "❌ Error: No settings.json file found!"
    exit 1
  fi
fi

# Check if copilot-api is already running on port 4141
if lsof -Pi :4141 -sTCP:LISTEN -t >/dev/null 2>&1; then
  RUNNING_PID=$(lsof -Pi :4141 -sTCP:LISTEN -t)
  echo "✅ Copilot API already running on port 4141 (PID: $RUNNING_PID)"
  echo "   Server running on http://localhost:4141"
  # Update PID file if it doesn't match
  if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if [ "$OLD_PID" != "$RUNNING_PID" ]; then
      echo "$RUNNING_PID" > "$PID_FILE"
    fi
  else
    echo "$RUNNING_PID" > "$PID_FILE"
  fi
  exit 0
fi

# Clean up stale PID file if it exists
if [ -f "$PID_FILE" ]; then
  rm "$PID_FILE"
fi

# Start copilot-api in background
echo "🚀 Starting copilot-api server on port 4141..."
echo "   Logs: $LOG_FILE"
cd "$PROJECT_ROOT"
# Just start the server without --claude-code flag (config is in .claude/settings.json)
nohup npx copilot-api@latest start </dev/null > "$LOG_FILE" 2>&1 &
COPILOT_PID=$!

# Save PID
echo $COPILOT_PID > "$PID_FILE"

# Wait a bit and check if it's running
sleep 3
if ps -p $COPILOT_PID > /dev/null 2>&1; then
  echo "✅ Copilot API started successfully (PID: $COPILOT_PID)"
  echo "   Server running on http://localhost:4141"
  echo "   Check logs with: tail -f $LOG_FILE"
else
  echo "❌ Failed to start copilot-api"
  echo "   Check logs: $LOG_FILE"
  rm "$PID_FILE"
  exit 1
fi
