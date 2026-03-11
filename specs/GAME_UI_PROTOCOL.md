# GiTF Game UI Protocol Specification

This document defines the interface for building a 3D "God Mode" visualization for the GiTF autonomous software factory.

## Connection

*   **URL:** `ws://localhost:4000/socket/websocket`
*   **Protocol:** Phoenix Channels (V2 JSON)
*   **Topic:** `game:control`

To connect from a non-Phoenix client (e.g., Unity/C#, Godot/GDScript), you need a Phoenix Channel client library or implement the handshake manually.

### Handshake (Raw Websocket)

1.  Connect to `ws://localhost:4000/socket/websocket`.
2.  Send Join Message:
    ```json
    ["1", "1", "game:control", "phx_join", {}]
    ```
3.  Receive Reply (Success):
    ```json
    ["1", "1", "game:control", "phx_reply", {"response": {}, "status": "ok"}]
    ```

---

## Outbound Events (GiTF -> Game)

GiTF pushes these events to the client.

### 1. `world_state`
Sent immediately upon joining. Represents the full snapshot of the factory.

**Payload Schema:**
```json
{
  "missions": [
    {
      "id": "mission-123",
      "name": "Refactor Auth",
      "status": "active",
      "current_phase": "implementation",
      "sector_id": "sector-main"
    }
  ],
  "ghosts": [
    {
      "id": "swift-recon-ab12",
      "name": "Swift Recon",
      "status": "working",
      "op_id": "op-456",
      "context_percentage": 0.45
    }
  ],
  "sectors": [
    {
      "id": "sector-main",
      "name": "Main Repository",
      "path": "/data/gitf/worktrees/main"
    }
  ]
}
```

### 2. `gitf_event`
Real-time telemetry updates. Use these to animate the 3D world (e.g., spawn a ghost model, flash a mission node).

**Payload Schema:**
```json
{
  "type": "string",
  "timestamp": 1708456000123,
  "data": { ... }
}
```

**Event Types:**

| Event Type | Data Fields | Description | Visual Cue |
| :--- | :--- | :--- | :--- |
| `gitf.ghost.spawned` | `ghost_id`, `op_id`, `sector_id` | A new ghost has entered the factory. | Spawn Ghost model at Sector location. |
| `gitf.op.started` | `op_id`, `mission_id` | A ghost started working on an op. | Draw line between Ghost and Mission. |
| `gitf.op.completed` | `op_id` | Work finished. | Ghost deposits payload at Mission, turns green. |
| `gitf.op.failed` | `op_id` | Work failed. | Ghost turns red, emits smoke/particles. |
| `gitf.mission.phase_transition` | `mission_id`, `from`, `to` | Mission moved to next phase. | Mission node pulses/changes color. |
| `gitf.alert.raised` | `type`, `message` | System alert. | Flash screen/UI warning. |

---

## Inbound Commands (Game -> GiTF)

The game client can send these messages to control the factory.

### 1. `spawn_mission`
Create a new work order.

**Message:**
```json
["ref", "topic", "spawn_mission", {
  "goal": "Build a login page",
  "sector_id": "sector-main"
}]
```

**Response:**
```json
{"status": "ok", "response": {"mission_id": "mission-789"}}
```

### 2. `emergency_stop`
Kill all active ghosts immediately.

**Message:**
```json
["ref", "topic", "emergency_stop", {}]
```

**Response:**
```json
{"status": "ok", "response": "ok"}
```

---

## 3D Visualization Guidelines

*   **Sectors:** Represent as hexagonal landing pads or facility zones.
*   **Missions:** Represent as large floating crystals or monoliths above the pads. Color code by phase (Research=Blue, Implementation=Orange, Audit=Purple).
*   **Ghosts:** Represent as translucent operatives moving between the factory center (or Sector) and the Mission monoliths.
*   **Budget:** Display a "Burn Rate" meter in the HUD.
