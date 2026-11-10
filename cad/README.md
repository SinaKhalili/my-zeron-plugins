# CAD

Parametric 3D CAD beside your chat, in the spirit of AI CAD tools: you describe a part, the agent models it, and you shape it with the mouse, sliders and sketches.

## Using it

- **Open it** with the cube button in a chat's header. It also opens by itself when an agent sets the chat's design. Each chat has its own design, kept in the plugin's database.
- **Ask for a part** in the chat ("a wall bracket for a 25 mm pipe, with two screw holes"), or in the CAD tab's ask box. The ask box drafts the message in the composer, naming the selected part when there is one. The agent writes the design through the plugin's tools and gets back the build: errors with the failing node's path, bounds, and parts.
- **The viewport**: drag to orbit, Shift-drag (or Shift-scroll) to pan, scroll to zoom. Iso, Top, Front and Right set the view. The header has fit, see-through, orthographic and perspective.
- **Mouse modelling**: choose Box, Cylinder or Sketch, then Add or Cut and a height or depth. Click on the grid or on a flat face. A box takes two corners, a cylinder a centre and a radius, and a sketch takes points (click the first point, or Close, to finish). Measure gives the distance between two clicks.
- **Parameters** are the design's sliders and switches. Dragging one rebuilds live.
- **Parts and Selected**: click a part in the view or in the list to edit its numbers (expressions work: `width/2 - 3`), move or turn it, set it to Add, Cut or Intersect, colour it, duplicate it or delete it.
- **Files**: open and save a design as `.json`, and export STL for printing.
- **Section** (scissors): cut the model across X, Y or Z with a slider. The cut faces fill in orange-red, a dashed frame shows the plane, and a toggle keeps the other side.
- **Exploded view** (split icon): each feature that adds material becomes its own piece, keeping its holes, and flies out from the middle while the base stays on the plate. A slider and a Collapse/Explode button control it.
- **Variants** (palette icon, or ask for options): the agent proposes up to 6 takes with `propose_variants`. They line up side by side with live thumbnails. Point at one to preview it full-size, click to pin the preview, and Use to adopt it as an undoable change. Variants live only while the window is open.
- **History**: every change, yours or the agent's, is listed with a label ("Width 76 → 100", "AI: widened the strut"). Point at a row to preview that version, click to pin it, and Restore to bring it back as a new change.
- **Point-and-ask**: click a face and a pin marks the exact spot. The chips (Hole here, Round its edges, Thicker here, Boss here, Ask…) draft a request with the point, the face's direction and the part, and `get_design` gives the agent the same `face`.
- **The bottom panel** resizes from the divider above it. A double-click folds it to its tabs, and choosing a tab opens it again.

## The design format

A design is JSON: `params` (sliders), `vars` (derived values), and `body`, a feature list where each node is added, cut (`mode: "cut"`) or intersected with what came before. The nodes are box (with rounded vertical edges), cylinder and cone, sphere, torus, extrude (a polygon or a circle), revolve (a profile about Z), and group, union, difference and intersection. Any node can take translate, rotate, scale, mirror, mirror_copy, linear (`repeat`) and circular (`radial`) patterns, and `if` for options. Any number may be an expression of the parameters. The full reference is the `set_design` tool's description in `zeron-plugin.json`.

## How it works

Everything runs in the plugin's sandbox, with nothing to install:

- `expr.luau` evaluates expressions.
- `csg.luau` does booleans on polygon solids with BSP trees, iteratively, pausing every few milliseconds so a heavy build is cut into slices that fit a plugin call's time budget.
- `geom.luau` builds primitives, transforms and patterns.
- `designs.luau` holds each chat's design: undo and redo, builds that coalesce while a slider is dragged, the indexed mesh with its crease edges, and STL export.
- `render.luau` draws the viewport in software on a canvas. Faces come back to front by walking a BSP tree from the camera, so overlaps are always right, and exploded pieces each walk their own tree. They're flat-shaded by a camera-mounted light, with outlined creases, faces cut at the near plane, a grid and an axis triad. It also picks parts and casts rays onto faces and planes.
- `designs.luau` also runs the background jobs (section cuts, exploded pieces, variants, version previews) one at a time, and keeps the labelled history in the plugin's database.
- `gpu.luau` draws the viewport on the GPU where Zeron has it (0.2.139-beta.4 and later: `ui.scene3d` with a mesh of its own triangles): flat-shaded parts with depth, multisampling, a sun that casts shadows, and outlines as thin tubes along the creases. The canvas renderer stays as the fallback on older builds and for the orthographic view, and still draws the History and Variants thumbnails. The grid sits on a canvas under the scene; sketches, pins and the axes sit on one over it. Picking casts a ray against the triangles, so it works the same on both.
- `view.luau` is the tab.
