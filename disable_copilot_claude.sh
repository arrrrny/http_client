#!/bin/bash
# Disable Claude Copilot mode
# This will rename .claude folder to .claude_local
# Use --kill flag to also stop the copilot-api server

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$PROJECT_ROOT/.claude"
CLAUDE_LOCAL_DIR="$PROJECT_ROOT/.claude_local"
PID_FILE="$PROJECT_ROOT/.copilot_pid"
KILL_SERVER=false

# Parse arguments
if [ "$1" = "--kill" ]; then
  KILL_SERVER=true
fi

echo "🛑 Disabling Claude Copilot mode..."

# Stop copilot-api server only if --kill flag is provided
if [ "$KILL_SERVER" = true ]; then
  if [ -f "$PID_FILE" ]; then
    COPILOT_PID=$(cat "$PID_FILE")
    if ps -p $COPILOT_PID > /dev/null 2>&1; then
      echo "🛑 Stopping copilot-api server (PID: $COPILOT_PID)..."
      kill $COPILOT_PID
      sleep 1

      # Force kill if still running
      if ps -p $COPILOT_PID > /dev/null 2>&1; then
        kill -9 $COPILOT_PID
      fi

      echo "✅ Copilot API stopped"
    else
      echo "⚠️  Copilot API not running"
    fi
    rm "$PID_FILE"
  else
    echo "⚠️  No PID file found, checking for running processes..."
    # Try to find and kill any running copilot-api processes
    pkill -f "copilot-api.*start" && echo "✅ Killed copilot-api processes" || echo "⚠️  No copilot-api processes found"
  fi
else
  echo "ℹ️  Keeping copilot-api server running (use --kill to stop it)"
fi

# Rename .claude to .claude_local
if [ -d "$CLAUDE_DIR" ]; then
  if [ -d "$CLAUDE_LOCAL_DIR" ]; then
    echo "⚠️  Warning: .claude_local already exists. Removing it first..."
    rm -rf "$CLAUDE_LOCAL_DIR"
  fi
  mv "$CLAUDE_DIR" "$CLAUDE_LOCAL_DIR"
  echo "✅ Renamed .claude to .claude_local"
else
  echo "⚠️  .claude folder not found (may already be disabled)"
fi

echo "✅ Claude Copilot mode disabled"
