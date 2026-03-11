# Ratatouille TUI Refactor Plan

This document outlines the strategy for rebuilding the GiTF TUI using the `ratatouille` library.

## Goals
- **Stability:** Use Ratatouille's robust layout engine to eliminate scrolling/wrapping bugs.
- **Maintainability:** Separation of concerns using Model-View-Update (MVU) architecture.
- **Aesthetics:** Clean, bordered panels with consistent styling.

## Architecture

The TUI will be rebuilt in `lib/gitf/tui/` with the following structure:

### 1. `GiTF.TUI.App`
The entry point application module implementing `Ratatouille.App`.
- **Model:** Holds the state (`chat`, `activity`, `input`).
- **Update:** Handles events (`:resize`, keys, PubSub messages).
- **View:** Defines the root layout using `<view>`, `<row>`, `<column>`.

### 2. `GiTF.TUI.Constants`
- Define themes (colors), dimensions, and layout constants.

### 3. Components (Views)
Ratatouille uses a declarative view tree. We will define helper functions to render specific sections:

- **`GiTF.TUI.Views.Chat`**
  - Renders the chat history.
  - Uses `<viewport>` for scrolling.
  - Renders styled text for User/Assistant/System messages.

- **`GiTF.TUI.Views.Activity`**
  - Renders the "Activity" panel.
  - Sections:
    - **Factory Status:** Health checks, global metrics.
    - **Ghosts:** Table of active ghosts.
    - **Missions:** List of active missions.

- **`GiTF.TUI.Views.Input`**
  - Renders the input bar at the bottom.
  - Handles the prompt character (`> `, `/ `, etc.).
  - Shows the current input text.

### 4. Logic & State Management
We will port the existing logic from the deleted components into new context modules:
- `GiTF.TUI.Context.Chat` (Manages history buffer)
- `GiTF.TUI.Context.Input` (Manages text editing, history, cursor)
- `GiTF.TUI.Context.Activity` (Manages stats snapshots)

## Layout Structure

```
+-------------------------------------------------------+
|  Chat (Flex 2)            |  Activity (Flex 1)        |
|                           |                           |
|  [System] ...             |  Factory: OK              |
|  > User msg               |                           |
|                           |  Ghosts (2)               |
|                           |  - Ghost 1 [working]      |
|                           |                           |
+---------------------------+---------------------------+
|  Input                                                |
|  > Type here...                                       |
+-------------------------------------------------------+
|  Status Bar: 0 ghosts | $0.00                         |
+-------------------------------------------------------+
```

## Implementation Steps

1.  **Dependencies:** Verify `ratatouille` installs and compiles.
2.  **Scaffolding:** Create `GiTF.TUI.App` with a basic "Hello World" view.
3.  **Input:** Implement the Input view and keyboard handling (typing, backspace, enter).
4.  **Chat:** Implement the Chat view and connect it to `handle_submit`.
5.  **Activity:** Implement the Activity view and connect it to PubSub.
6.  **Polish:** Refine colors, borders, and scrolling behavior.

## Key Changes from Legacy
- No manual string padding (`String.duplicate(" ", n)`).
- No manual border construction (`┌──┐`).
- Use `<panel title="...">` provided by Ratatouille (or build a standard bordered view helper).
