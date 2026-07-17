# Design canvas versus the ttk surface: what renders, what substitutes

The accepted design (the `Questlog - Design overview` canvas) is drawn in React and CSS in a macOS Aqua idiom. The application renders through ttk's `clam` theme, Tk `text` widgets with tags, and SVG rasterised in core by Tk 9. This records, element by element, how the application realises the design and where the toolkit's ceiling forces a substitution. The governing rule is behaviour over pixels: the design's information architecture is reproduced in full; its macOS finish is approximated, not required.

## Rendered faithfully

- **Rounded chips and pills.** An SVG rounded rectangle rasterised to a `photo` and used as a 9-patch image element behind a ttk button/frame or a label (`ui/theme.tcl`). Corner radius survives arbitrary widths.
- **Filled pill backgrounds.** The SVG `rect` fill is the pill body; the word is a label drawn over it with `-compound center`.
- **Inline highlighted (marked) text.** A text tag with `-background` lights a matched span, used for search hits and the query lit inside a former-name breadcrumb.
- **Multi-column alignment.** Text-widget `-tabs` right/left stops, computed from font metrics, hold the metadata columns and the criteria rows in line at any DPI.

## Substituted (design element to clam realisation)

- **Gradient fills** (the blue segment and pill gradients) become **flat solid fills**. The core SVG rasteriser's gradient support is unreliable, and the chip helpers emit a solid `fill`. A selected view segment reads by a solid accent rather than a top-to-bottom gradient.
- **Drop shadows and soft elevation** become **border and fill contrast**. Neither the text widget nor ttk carries a shadow property, and the rasteriser renders no filter primitives. Depth is drawn with a hairline border and a tint step.
- **Glass and blur** (translucent menus and panels) become **opaque surfaces**. There is no compositor blur to draw through.
- **Rounded dropdown popups** become **native ttk menus** with square corners. The corner-rounding technique applies to buttons, frames, and labels, not to a popup list.
- **A colored left accent rail** of real border weight becomes **a fixed-width bar glyph** coloured by a tag foreground. It is one character cell wide, not an edge of arbitrary thickness.

## Not reproduced

- **The macOS window chrome** (rounded window body, traffic-light buttons, centred 28px titlebar) is the platform's own X11/ttk frame instead.
- **The native Cocoa Fonts panel** (Collection / Family / Typeface / Size columns, effects strip, preview) is not built. The reading pane keeps its live re-font control, which reconfigures the body font in place on pick.

## Reading a design screen against the app

Where a design screen shows a gradient, read a solid fill; where it shows a shadow or glass, read a border and an opaque surface; where it shows a macOS window, read a native frame. The search-and-restrict toolbar, the criteria chips and their collapse, the session-name breadcrumb, and the reload boundary are all reproduced as drawn; the view filters render on the list's own strip rather than as a toolbar row. Only the finish is approximated.
