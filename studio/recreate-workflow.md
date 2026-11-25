# Eclipse for reference recreation

Use this resource with your vault's `replicate-anything` and `rbx-video-reference-match` workflows. It describes tool inputs and how to keep effects, poses, and camera keys on an editable Eclipse timeline.

## Target and evidence

1. Call `eclipse_list_studios` and `eclipse_select_studio` with the intended Studio ID. Run `eclipse_capabilities` and confirm `Build` is `v1.0979`, `Version` is 6, and `mcpVersion` is 1.
2. Record the reference's source FPS and timestamps. Use the vault's reference tools to mark anticipation, contact, flash, camera cuts, holds, and recovery. Keep observed poses and timings distinct from estimates for occluded frames.
3. Inspect project and rig tracks with `ProjectInfo`, `ListTracks`, `ListProperties`, `ListKeys`, and `ListIK`. Preserve the actual player avatar handoff in the game. Use inherited `video_to_animation` or `import_animation_pack` for an editable source clip when appropriate. For close reference matching, pass `preserve_timeline: true` and compare `smoothing_window: 1` against the default around fast impacts. Open the clip using `OpenProject`.
4. Audition 10–20 distinct textures per major effect per round from authorized vault and catalog assets. Keep camera, coverage, lighting, and effect settings fixed. Capture contact, peak, and fade and inspect the flipbook in motion. Use the largest mismatch as the next search query until a candidate is close enough or the remaining mismatch is explicitly known. Avoid ContentProvider preloads through Studio MCP.

## Timeline protocol

Call `eclipse_action` with an `action` and a `request`. Instance references are `{"$instance":["Workspace","My Rig"]}`. Use the entire returned object reference (including `$ref`) when passing a track, camera, or rig back to Eclipse. References are valid for the current Studio session. This preserves identity for renamed cameras and joints that share a display name. Read the current tracks after reopening a project.

Typed values include `{"$type":"CFrame","values":[x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22]}` and the three-component translation form. NumberSequence points are `[time,value,envelope?]`. ColorSequence points are `[time,r,g,b]`. Vector3, Color3, UDim, UDim2, NumberRange, BrickColor, and Enum are also supported. For Enum use `{"$type":"Enum","enum":"Material","name":"Neon"}`. Positions are in studs and FOV is in degrees.

| Action | Request fields |
|---|---|
| `OpenProject` | New project `Name?, Rig?`; saved project `Target` from `ListProjects`; saved clip `Rig, Sequence`. `SaveCurrent: true` explicitly saves dirty work before switching. |
| `SetTimeline` | `FPS?, StartFrame?, EndFrame?, Loop?`. Set FPS before laying down source frames. |
| `ListTracks`, `ListProperties` | `Target?` for tracks and `Target` for property discovery. Use the returned Property identifier when present. |
| `ListKeys` | `Target?, Property?, First?, Last?, Limit?, IncludeChannels?`. It returns per-track keys, full count, and a next frame when paginated. |
| `SetKeyframe`, `SetEasing`, `DeleteKey` | `Target, Property?, Frame, Value?, Easing?`. Easing is `{Style,Direction?}`. Transform Value is a local CFrame. Omitting Value captures the current pose. |
| `SetCurve`, `FilterRotation` | Curve `Target, Property?, Frame, Channel?, Bezier?, HandleType?, In?, Out?`. `Bezier` is `[x1,y1,x2,y2]`. Graph tangents are relative time in seconds and value offsets for one channel. Filter rotation takes `Target, Property?`. |
| `CreateCamera`, `KeyCamera`, `CameraView` | Create `Name?, CFrame?, FOV?`. Key `Target, Frame, View?, FOV?, Easing?` using the desired world view. Sample `Target, Frame?, Apply?, Unshaken?` to read or show the authored camera. |
| `ListIK`, `SetIK`, `SetPoleFollow`, `KeyIKControl` | List `Rig`. Toggle `Rig, Target, Frame?, Enabled` with the chain Target from `ListIK`. Key `Rig, Target, Frame?, Control, Value` with a world CFrame. Controls include target, pole, roll, root where the chain supports them. |
| `ListEvents`, `PutEvent`, `DeleteEvent` | Cue `Rig, Id?, Frame, Duration?, Name?, Enabled?, Markers?, Emits?, Sounds?, Subtitle?, Sine?, CodeBegin?, CodeEnd?`. A native emit row is `{Target, Count?, Action?, Mode?}`, with Target below the event rig. Sine is `{Target, Mode?}` and requires the SineVFX client runtime in ReplicatedStorage. Include outside VFX and its runtime as cutscene export dependencies wherever appropriate. Delete `Rig, Id`. |
| `SetParenting`, `ApplyMotionPath`, `RetimeKeys` | Parenting `Rig, Frame, Mode, Target?, Parent?, World?, Parented?` (ChildOf, CameraAttachment, or LocalSpace). Path `Target, Property?, Points, First, Last, Step?, Offset?, Easing?` using typed Vector3 points with TransformChannels enabled. Use ReadPreferences and SetPreferences for this setting. Select or move keys with `Keys: [{Target,Property?,Frame}], Delta?`. |
| `CreateScreenEffect` | An Eclipse effect track with `Kind, StartFrame, Camera?, Settings?`. Impact Frames takes `Frames: [{image,delay,hold}]`. Camera Shake takes `Strength?, Speed?, Duration?, Envelope?`. Afterimages take `Target, Settings?`. |
| `ReadPreferences`, `SetPreferences` | Read `Keys?, IncludeDefaults?`. Set `Changes` using Eclipse preference names and values. |
| `ListLayers`, `EditLayer` | `Rig?` and use `Operation` Add, Select, Remove, Duplicate, Move, or Change. Pass `Id` for existing rows, `Direction` for Move, or `Field, Value` for Change. |
| `SeekFrame`, `Playback` | Seek `Frame, Samples?` for world transforms, or play and pause with `Play`. For image evidence use `eclipse_capture_frame`. |
| `ListEditorFeatures`, `EditorCommand`, `OpenPanel` | Discover editor commands and openable panels. Invoke a named command with `Command`, or open a specific tool with `Panel`. Commands that show a dialog or panel still inherit that interaction. |
| `SaveProject`, `ExportProject` | Save `Name?, RawOnly?`. Export `Kind` Archive, Animations, or Cutscene. Cutscene takes `Name, EndFrame, Camera?, CameraMode?, Mode?, ButtonLabel?, Dependencies?`. Cutscene places the playable module in ReplicatedStorage.EclipseCutscenes. |
| `BlenderCommand`, `VideoCommand` | Blender `Command` Status, Connect, Pull, Push, Disconnect. Video Status, Retry, Enable, Disable. Both use Eclipse's own companions. |

Use `eclipse_batch` for an undoable group of supported pose, timing, camera, curve, IK, and cue edits. Keep the first batch small and read it back before writing dense keys. Use `SetCurve` and world sample comparisons to correct the interpolation between key poses. Save the editable project before packaging a playable copy.

## Verification

1. Seek and capture equivalent reference frames at the same camera, framing, and FOV. Check contacts, silhouette, camera ease, flash timing, and settling.
2. Trigger the packaged shot through its normal Play entry point or `eclipse_run_export` in a Studio client playtest. Record with `eclipse_record_playtest` and compare to the source using the vault's timestamped comparison tools. Complete the vault's four correction loops or report any blocked checks.
3. Reopen the Eclipse project to check persistence. Report observed offsets, missed cues, original and rebuilt captures, and any unverified angle or effect. A similar-looking still establishes only that frame.
