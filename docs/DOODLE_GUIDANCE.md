# Bibbles doodle guidance

The overlay is a native vector canvas on the display the user points at. It has a restrained paper-and-ink style: smooth, slightly irregular strokes, warm contrast outlines, four accent colors, and a small smiling companion. It is click-through and never moves or clicks the system pointer.

## Two interactions

Local drawing commands need only a transcript or typed command. Supported shapes: triangle, circle, rectangle/box, arrow, line, underline, star. Examples: “draw a coral circle here”, “draw an arrow on my screen in purple”, “undo drawing”, “clear drawings”. Up to 12 marks accumulate on one display, and Escape clears them. The menu also offers Undo Drawing and Clear Drawings. A different display or a screen-analysis request starts a fresh scene. Unsupported compound or target-specific commands are not represented as generic local shapes.

Screen guidance uses the existing capture/model request. Optional annotations contain `kind`, `target`, `confidence`, and `label`. Kinds are circle, rectangle, arrow, and underline. Each target is a normalized top-left rectangle around an actual visible object; arrow rectangles designate the destination object. At most four marks are accepted. They must have finite, in-range coordinates, area no larger than 20% of the image, and confidence of at least 0.72. Invalid entries are dropped without discarding the answer, and original step numbers are preserved. Legacy single-target responses remain supported.

Before drawing, the app revalidates capture age and display geometry. Labels try several positions and are omitted if they collide with a target or another label. Guidance disappears after 12 seconds. This is snapshot guidance: it does not continuously track objects after scrolling or moving a window.

## Rendering and performance

The app renders CGPaths with Core Animation; no generated image or model round trip is needed to draw a shape. Pen reveal lasts 380 ms and companion travel lasts 300 ms. Reduce Motion disables both. Local marks persist without running animations; only the short-lived scanning indicator repeats a pulse. Existing local marks do not redraw their reveal animation when another shape is added. Small amounts of geometry and layers are bounded in memory.

## Validation

`DoodleArtworkTests` checks display-edge placement, negative display origins, and command ambiguity. Provider tests cover unsafe annotation filtering and fallback on malformed primary responses. `scripts/DoodlePreview.swift` renders a synthetic light/dark design fixture with the production artwork code, without a screenshot or network request.

Live model localization, per-app overlay appearance, physical response latency, and scrolling behavior remain physical-Mac acceptance checks. The preview and unit tests do not establish live target accuracy or production readiness.
