# Manual Verification: Epic 6 — Markdown Rendering

## Prerequisites

- [ ] A logged-in account with at least one Markdown note in the Notes folder
      (or create a new note via the `+` button in the Notes tab).
- [ ] Device or simulator running iOS 16+.

## Steps to Verify

### Happy Path

1. Open any existing note (or create a new one) so `NoteEditorView` is showing
   the raw `TextEditor`.
2. Replace the note body with a document that exercises every Epic 6 feature,
   e.g.:

   ```markdown
   # Heading 1
   ## Heading 2
   ### Heading 3

   Some **bold**, *italic*, ~~strikethrough~~, and `inline code` text, plus a
   [link to example.com](https://example.com).

   - Unordered item
     - Nested unordered item
   1. Ordered item
   2. Ordered item

   - [ ] Unchecked task
   - [x] Checked task

   | Left | Center | Right |
   | :--- | :---: | ---: |
   | a | b | c |
   | d | e | f |

   > A quote.
   > > A nested quote.

   ```swift
   func example() -> Int {
       return 42
   }
   ```

   ---

   ![A placeholder image](https://picsum.photos/400/200)

   Here's a footnote reference[^1] and another[^note].

   [^1]: The first footnote's text, with **bold** inside it.
   [^note]: A word-labeled footnote.
   ```

3. Tap the "Preview" (eye icon) button in the top toolbar.
4. Tap the "Edit" (eye-slash icon) button to switch back to the raw editor.

## Expected Results

- **Headings**: H1/H2/H3 render at progressively smaller, bold system font
  sizes.
- **Inline formatting**: bold, italic, strikethrough, and inline code are
  visually distinct; the link is tappable and colored as a link; tapping it
  opens Safari (or an in-app browser) at `https://example.com`.
- **Lists**: the unordered list shows bullet markers with the nested item
  indented further; the ordered list shows `1.`/`2.`.
- **Task lists**: the unchecked item shows an empty square glyph, the checked
  item shows a checked square glyph. Tapping them does **not** toggle state
  (read-only in this epic).
- **Table**: three columns, header row bolded, column alignment matches the
  `:---`/`:---:`/`---:` markers (left/center/right), and the table scrolls
  horizontally if it doesn't fit the screen width without clipping content.
- **Block quote**: shown with a leading vertical bar and indent; the nested
  quote is indented further than the outer one.
- **Code block**: monospaced font on a shaded rounded background, with
  "swift" shown as a small language label above it; internal indentation
  (the `return 42` line) is preserved.
- **Thematic break**: a horizontal divider line appears.
- **Image**: loads and displays inline, scaled to fit the width, with a
  spinner while loading and a broken-image placeholder if the URL fails to
  load (test by temporarily using an invalid image URL).
- **Footnotes**: `[^1]` and `[^note]` appear in the body as small tappable
  superscript-style markers showing "1" and "2" respectively (numbered by
  order of first appearance in the body, not by definition order). Tapping a
  marker scrolls down to a "Footnotes" section at the bottom of the preview
  listing both definitions next to their numbers, with the bold text inside
  footnote 1 still rendering as bold.
- **Preview/Edit toggle**: switching to Preview hides the raw `TextEditor`
  and Find & Replace button (grayed out) and shows the rendered view instead;
  switching back to Edit restores the raw Markdown source exactly as typed
  (no data loss/mutation from toggling).
- **Word/char count status bar**: remains visible and accurate in both Edit
  and Preview modes.

### Edge Cases

1. **Empty note**: open a blank note and toggle to Preview — should show an
   empty scroll area with no crash.
2. **Footnote reference with no definition**: type `Stray ref[^9] here.` with
   no matching `[^9]: ...` definition anywhere in the note, then Preview —
   `[^9]` should render as plain literal text (not a broken/blank link).
3. **Very large table**: paste a table with 6+ columns and Preview — table
   should scroll horizontally rather than compressing/clipping columns off
   the visible screen.
4. **Long unbroken code line**: a fenced code block with a very long single
   line should scroll horizontally within its own container rather than
   wrapping awkwardly or pushing the whole screen width.
5. **Deeply nested list** (3+ levels of nested `-` items): each level should
   visibly indent further than its parent without layout breaking.
6. **Toggle Preview repeatedly while autosave is pending**: make an edit,
   quickly tap Preview before the 1.5s autosave debounce fires, then tap Edit
   again — the edit should still be present and should still autosave
   normally (Preview mode does not interfere with the autosave timer).

## Not Covered By This Verification

- Epic 7's real Edit/Preview/Split View UI (this epic only ships a minimal
  placeholder toggle).
- Resolving Neutrino Drive attachment references in images (Epic 17 scope) —
  only standard `https://...` image URLs are expected to render.
- Interactive (tap-to-toggle) task list checkboxes — read-only in this epic.
