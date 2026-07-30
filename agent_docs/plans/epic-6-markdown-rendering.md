# Plan: Epic 6 — Markdown Rendering

Branch: `feature/epic-6-markdown-rendering`

## What is changing and why

Epic 5 shipped a raw-text Markdown editor (`NoteEditorView` + `TextEditor`) with no
rendering anywhere in the app. Epic 6's milestone is "Rendering matches the web
version": add a read-only SwiftUI Markdown renderer covering headers, lists,
checklists/task lists, tables, images, code blocks, quotes, links, horizontal
rules, and footnotes. Epic 7 (out of scope) will later add proper Edit/Preview/
Split View mode switching; this epic only needs a way to *see* the rendering, so
we add a minimal, throwaway "Preview" toggle to `NoteEditorView`'s toolbar that
swaps `TextEditor` for the new renderer. That toggle is explicitly expected to be
replaced by Epic 7.

## Parser choice: `apple/swift-markdown`

Decision: add `apple/swift-markdown` (SPM) rather than hand-rolling a CommonMark
parser.

Rationale:
- It wraps `swift-cmark` (a fork of `cmark-gfm`) and parses CommonMark + the GFM
  extensions (tables, strikethrough, autolink, tagfilter, tasklist) out of the
  box, which covers headers, lists, ordered/unordered nesting, checklists/task
  lists, tables, code blocks, block quotes, thematic breaks, links, and images
  with a battle-tested parser instead of a hand-rolled one — much lower risk of
  subtle CommonMark edge-case bugs (e.g. list-tightness, nested blockquotes,
  table alignment rows).
- Pure Swift/C, no platform-specific frameworks — builds fine as an iOS SPM
  dependency alongside `swift-sodium` (same pattern already used in
  `project.yml`).
- Gap: **footnotes are not part of GFM** (GFM's cmark-gfm extensions are table /
  strikethrough / tagfilter / autolink / tasklist only — no footnote extension).
  `[^1]` and `[^1]: text` are otherwise inert literal text to cmark. This is
  handled with a small pre/post-processing pass (see below) rather than pulling
  in a second Markdown engine.

## Footnote handling (pre/post-processing around swift-markdown)

1. **Pre-process** the raw source before handing it to `Markdown.Document`:
   - Regex-extract footnote definition lines matching `^\[\^([^\]]+)\]:\s?(.*)$`
     into a `[label: String]` dictionary and strip those lines from the body.
     (Multi-line footnote definitions with indented continuation lines are a
     known, documented limitation — out of scope for this epic.)
   - Rewrite in-body references `[^label]` (not immediately followed by `:`,
     which would be a definition) into a real CommonMark inline link:
     `[^label](nn-footnote://label)`. cmark now parses this as an ordinary
     `Link` node with text `^label` and destination `nn-footnote://label` — no
     custom parsing needed for the reference itself.
2. **Parse** the rewritten body with `Markdown.Document(parsing:)` and walk the
   AST into our own pure-Swift model (below).
3. **Post-process**: while walking, any `Link` whose destination has the
   `nn-footnote://` scheme becomes `MarkdownInline.footnoteReference(label:index:)`
   instead of a normal link. Footnote index numbers are assigned in order of
   first appearance in the body (standard footnote numbering), falling back to
   definition order for unreferenced definitions. Each definition's raw text is
   itself parsed for inline formatting (bold/italic/code/links) so footnotes
   aren't limited to plain text.
4. Rendered output: an inline superscript, tappable marker in the body; a
   "Footnotes" section appended after the document body listing each
   definition next to its number.

## Layers affected

- **Dependency**: `project.yml` gains `apple/swift-markdown` (product
  `Markdown`) alongside `swift-sodium`, added to the `NeutrinoNotes` target only
  (not the test target's own product needs — the test target depends on the
  `NeutrinoNotes` target and inherits it). Re-run `xcodegen generate` after
  editing.
- **New pure-Swift model + parser** (no `import SwiftUI`, independently
  testable):
  - `NeutrinoNotes/Rendering/MarkdownModel.swift` — `MarkdownDocumentModel`,
    `MarkdownBlock`, `MarkdownInline`, `MarkdownList`, `MarkdownListItem`,
    `MarkdownTable`, `MarkdownTableColumnAlignment`, `MarkdownFootnote`. All
    `Equatable` for easy assertions in tests.
  - `NeutrinoNotes/Rendering/MarkdownParser.swift` — `enum MarkdownParser { static
    func parse(_ source: String) -> MarkdownDocumentModel }`, wraps
    swift-markdown + the footnote pre/post-processing above.
  - `NeutrinoNotes/Rendering/MarkdownInlineRenderer.swift` — pure function(s)
    converting `[MarkdownInline]` to `AttributedString` (bold/italic/
    strikethrough/inline-code font+background/links via the `.link` attribute/
    footnote refs as superscript text with a custom `.link` pointing back at
    `nn-footnote://label` so SwiftUI `Text`'s built-in link-tap behavior can be
    reused and intercepted). Also `Foundation`-only, testable without SwiftUI
    hosting.
- **New SwiftUI views** (`NeutrinoNotes/Views/MarkdownView.swift`, or a
  `Rendering/` views sub-group — final call to the implementing agent, but
  keep pure model/parser files free of `import SwiftUI` either way):
  - `MarkdownView`: top-level `ScrollView` + `VStack` that parses the given
    Markdown string (via `MarkdownParser.parse`, recomputed with `.task`/
    `onChange` — no need to memoize aggressively for note-sized documents) and
    renders `document.blocks`, then a "Footnotes" section if
    `document.footnotes` is non-empty.
  - Block renderer(s) for: headings (`.font(.title)...title3` mapped from H1-H6,
    falling back to `.headline`/`.subheadline`/`.caption` for H5/H6), paragraphs
    (`Text(attributedString)`), ordered/unordered lists (recursive, indenting
    nested lists), task list items (checkbox glyph — read-only, not an
    interactive `Toggle`, since this view has no write-back to the source
    text), tables (SwiftUI `Grid`, respecting per-column alignment from the
    delimiter row), code blocks (monospaced `Text` in a scrollable, rounded
    background container; language info string rendered as a small label if
    present — no syntax highlighting, matches the epic's "monospaced font +
    background is sufficient" guidance), block quotes (leading vertical bar +
    indent, recursive for nesting), thematic breaks (`Divider`), images
    (`AsyncImage` with placeholder/failure states — standard Markdown image
    syntax only, no Drive-attachment resolution; that's Epic 17), and the
    footnotes section (numbered list of definitions).
  - Links open via `UIApplication.shared.open` by default (external
    http/https), except `nn-footnote://` links which are intercepted via a
    custom `OpenURLAction` in the environment and instead scroll to / reveal
    the matching footnote definition.
- **Minimal Preview toggle in `NoteEditorView`** (existing file): a new
  `@State private var isPreviewMode = false` and a toolbar button
  (`Label("Preview", systemImage: "eye")` / "Edit" + `"eye.slash"` when
  toggled) in the existing `.primaryAction` group. `editorBody` becomes a
  `Group` that shows `TextEditor` when `!isPreviewMode` and `MarkdownView(text:
  text)` when `isPreviewMode`; the status bar and find/replace stay tied to the
  editor and are hidden/disabled while previewing. This is explicitly flagged in
  a code comment as a placeholder for Epic 7's real mode-switching UI.

## Specialist agents needed

This repo's specialist roster (`rust-developer`, `frontend-developer`,
`ui-designer`, `test-writer`) targets a Rust+React stack, not Swift/SwiftUI —
there is no iOS specialist available. Adapting pragmatically:
- **`general-purpose`** agent for all Swift implementation (parser, model,
  renderer, views, `project.yml`/`xcodegen` changes) — closest available fit
  given full tool access, standing in for the missing "swift-developer" role.
- **`test-writer`** for the XCTest unit tests, targeting the pure-Swift
  `MarkdownParser`/`MarkdownModel`/`MarkdownInlineRenderer` API surface defined
  above (this is testable without a simulator UI host, matching the existing
  `NoteTextStatsTests.swift` style: `@testable import NeutrinoNotes`, `XCTestCase`,
  `test_<subject>_<condition>_<expectation>` naming).
- No `ui-designer` delegation — this is native SwiftUI composition against
  system fonts/colors/materials already used elsewhere in the app (`.bar`,
  `.secondary`, system `Label`/`SF Symbols`), not a bespoke visual design task.
  I will implement visual layout decisions directly as part of the SwiftUI
  view work.

## Known risks / edge cases

- **Cannot visually verify SwiftUI rendering** without a running simulator in
  this environment. Will build (`xcodegen generate` + `xcodebuild build`) and
  run unit tests, but the actual pixel output of `MarkdownView` will not be
  eyeballed. This will be called out explicitly in the PR/summary.
- `swift-markdown`'s exact default extension set (whether GFM tables/tasklist/
  strikethrough are on by default via `Document(parsing:)`) needs to be
  confirmed empirically via the unit tests once the dependency is fetched —
  if any extension is off by default, the parser needs the right
  `ParseOptions`/options flag.
- Inline images mixed mid-paragraph with text: `AttributedString`/`Text` can't
  host an inline `Image` view pre-iOS 17 the way we need generically. Plan:
  render a paragraph that is *entirely* a single image as its own block-level
  image (common case — "image on its own line"); for an image inline among
  other text, fall back to rendering `[image: alt-text]` as plain text in that
  run (documented limitation, not silently dropped).
- Footnote multi-line definitions, nested footnote definitions, and footnotes
  referenced from inside a table cell are out of scope / best-effort only.
- Table `Grid` rendering must not overflow horizontally off-screen on iPhone —
  wrap in a horizontal `ScrollView` per table.
- Task list checkboxes are **read-only** in this epic (no tap-to-toggle
  write-back to the Markdown source) — that's an editing feature, not a
  rendering one, and isn't in the Epic 6 bullet list.
- Regenerating `NeutrinoNotes.xcodeproj` via `xcodegen generate` after the
  `project.yml` dependency change is required before the new package resolves;
  first build will need SPM to fetch `swift-markdown` (network access
  required in the build environment).

## Acceptance criteria

- `xcodegen generate` succeeds with `apple/swift-markdown` added to
  `project.yml`.
- `MarkdownParser.parse(_:)` correctly models: H1-H6, unordered/ordered lists
  (incl. nesting), task list items (checked/unchecked), GFM tables with column
  alignment, fenced code blocks (with language preserved), block quotes (incl.
  nesting), thematic breaks, links, images, and footnote refs/definitions —
  covered by unit tests in `NeutrinoNotesTests/`.
- `MarkdownView` compiles and is wired into `NoteEditorView` behind the
  temporary Preview toggle.
- `cargo test`-equivalent here (`xcodebuild test`) passes for the new test
  files plus all pre-existing tests (no regressions).
- Project builds cleanly (`xcodebuild build` or `xcodegen generate` +
  `xcodebuild -scheme NeutrinoNotes build` against a simulator destination).
- `README.md` Epic status table and architecture paragraph updated; `agent_docs/
  road_map.md` Epic 6 checkboxes flipped to ✅.
- PR opened describing what was and wasn't visually verified.
