# Svelte drag-and-drop library comparison

**Research date:** 2026-09-19  
**Question:** What is a good Svelte-compatible drag-and-drop library for the Dublin Hema Club dashboard?

## Findings

### 1. Local prior art and evaluation criteria

There is no drag-and-drop dependency or existing drag/drop/sortable-list UI in the repository today. The frontend is SvelteKit 2.70.2 with Svelte 5.56.8 (runes), Tailwind, shadcn-svelte and bits-ui. TanStack Table's column sorting is not drag-and-drop prior art.

The likely future requirements are ordinary reorderable lists, moving inventory items/containers, and possibly kanban-style loan queues. The useful baseline is therefore: Svelte 5/runes ergonomics, cross-container moves, handles, nested or grid layouts, touch, keyboard/screen-reader alternatives, TypeScript, SSR-safe import/use, and a small enough surface to style consistently with shadcn-svelte.

Versions and npm metadata below are snapshots from the primary package pages as of this research date; they should be rechecked before adoption.

### 2. Ranked summary

| Rank | Library | Current signal | Svelte 5 fit | Accessibility posture | Main tradeoff |
|---|---|---|---|---|---|
| **1** | [`@thisux/sveltednd`](https://github.com/thisuxhq/sveltednd) | v0.8.0; npm page updated 2026-09-01 | Native Svelte 5, `$state`, actions and attachments | Opt-in keyboard Space/arrows/Escape and screen-reader announcements | Newer and less battle-tested than svelte-dnd-action; API/feature maturity should be proven in a spike |
| **2** | [`@atlaskit/pragmatic-drag-and-drop`](https://github.com/atlassian/pragmatic-drag-and-drop) | v3.0.0; npm page updated 2026-08-14 | Excellent: TypeScript vanilla core works with Svelte | Strong official guidance and optional live-region package, but accessible controls are not automatic | Low-level/headless: DHC must build sortable behavior, focus management, and keyboard alternatives |
| 3 | [`svelte-dnd-action`](https://github.com/isaacHagoel/svelte-dnd-action) | v0.9.77; npm page updated 2026-08-01 | Works with Svelte 5, but API/docs originated in Svelte 3/4 | Keyboard, ARIA and screen-reader instructions (described as beta) | Excellent feature coverage, but older event/action model and a history of `$state` compatibility fixes |
| 4 | [`SortableJS`](https://github.com/SortableJS/Sortable) | v1.15.7; npm page updated 2026-02-11 | Framework-agnostic DOM API, so it can be wrapped in a Svelte action | README documents no keyboard/screen-reader solution | Mature and feature-rich for pointer/touch lists, but accessibility and Svelte lifecycle integration are ours to supply |
| — | [`dnd-kit`](https://github.com/clauderic/dnd-kit) | Current repo has new packages, but Svelte adapter maturity is unclear | New architecture advertises `@dnd-kit/svelte`; verify release/docs before relying on it | Official README advertises keyboard, ARIA and live regions | Promising, but the Svelte adapter is newer than the established React ecosystem; not the conservative choice today |

### 3. `@thisux/sveltednd` — recommended first choice

The official README describes it as “Svelte 5 Native”, built on `$state`, with no external dependencies. Its npm page lists **v0.8.0**, MIT license, peer dependency `svelte: ^5.0.0`, and a last-update date of 2026-09-01. The repository has SvelteKit/Cloudflare adapter development dependencies, which is useful evidence that package development considers SSR-adjacent deployment, although it does not prove every import is SSR-safe. Sources: [README](https://github.com/thisuxhq/sveltednd), [npm package metadata](https://www.npmjs.com/package/@thisux/sveltednd).

**API and Svelte integration.** It exposes `use:draggable` and `use:droppable` actions, a reactive `dndState`, generic `DragDropState<T>`, and callbacks such as `onDrop`. The README also supplies a `$state<Task[]>` sortable-list example. Svelte 5.29+ attachments (`attachDraggable`/`attachDroppable`) let a component forward the behavior; ordinary actions remain suitable for native elements. This matches Svelte 5 runes and shadcn-svelte's component composition better than a wrapper around a React component. Source: [README attachment and sortable examples](https://github.com/thisuxhq/sveltednd).

**Features.** The first-party feature list and API document vertical, horizontal and grid layouts, nested containers, drop indicators, drag handles, interactive-element protection, disabled drag/drop and container identifiers for cross-container movement. It uses HTML5 Drag API for desktop and Pointer Events for touch/mobile. The zero-dependency claim is useful for bundle hygiene; no numeric bundle-size claim was found in the primary sources. TypeScript generics are first-class. Source: [README](https://github.com/thisuxhq/sveltednd).

**Accessibility.** The project says keyboard support is opt-in (Space/arrows/Escape) and includes screen-reader announcements. This is a better starting point than a raw DOM library, but “opt-in” means each DHC interaction still needs an accessibility review and an equivalent non-pointer action. The source does not establish a complete WCAG guarantee or screen-reader matrix. Source: [README accessibility section](https://github.com/thisuxhq/sveltednd).

**Risks.** The package is young relative to SortableJS and svelte-dnd-action, and the primary sources do not provide a mature compatibility matrix or a quantified release/bug history. Nested inventory structures should be tested rather than assumed to work perfectly. Use a client-only action/attachment boundary and ensure no module-scope DOM access is introduced in our own adapter; the SSR claim should be validated with `svelte-check` and a production build.

### 4. Atlassian Pragmatic Drag and Drop — second-choice fallback

Pragmatic Drag and Drop is a TypeScript, vanilla-JavaScript toolchain explicitly documented as usable with “any view library (eg `react`, `svelte`, `vue` etc.)”. Its official README calls the core approximately **4.7 kB**, headless, framework-agnostic, incremental, and split into entry points. The npm page lists **v3.0.0**, Apache-2.0, and an update date of 2026-08-14. Sources: [core documentation](https://atlassian.design/components/pragmatic-drag-and-drop/core-package), [GitHub README](https://github.com/atlassian/pragmatic-drag-and-drop), [npm](https://www.npmjs.com/package/@atlaskit/pragmatic-drag-and-drop).

**API and features.** `draggable({ element })`, `dropTargetForElements({ element })`, and `monitorForElements(...)` return cleanup functions. Separate entry points provide element/text-selection/external adapters, hitbox utilities and array reorder helpers. This sits naturally in a Svelte action (`onMount`/action setup, return cleanup) and `$state` remains entirely application-owned. It supports custom rendering and virtualization, but it is not a ready-made sortable-list component: DHC must calculate/reconcile list positions and render indicators. Source: [core API docs](https://atlassian.design/components/pragmatic-drag-and-drop/core-package).

**Browser and touch support.** Atlassian documents full feature support in Firefox, Safari and Chrome, on iOS and Android, plus virtualization support. Because it safely builds on browser drag/drop primitives, it is a good fit for custom inventory and kanban behavior; the core is still DOM-dependent and should only be initialized after mount. Source: [GitHub README](https://github.com/atlassian/pragmatic-drag-and-drop).

**Accessibility.** This is the critical tradeoff. The official accessibility guidance says the core does **not** automatically enable accessible controls. It requires an alternative to pointer dragging (buttons/menus/forms), meaningful names, live-region announcements, and focus restoration. The companion live-region package exposes `announce(...)`. This is an excellent, explicit accessibility model, but more implementation work than sveltednd. Source: [Atlassian accessibility guidelines](https://atlassian.design/components/pragmatic-drag-and-drop/accessibility-guidelines/).

### 5. `svelte-dnd-action` — credible compatibility fallback

The official repository and npm page describe a custom-action library with MIT license, **v0.9.77**, peer dependency `svelte >=3.23.0 || ^5.0.0-next.0`, and npm update date 2026-08-01. It has substantial adoption and documents production use. Source: [README](https://github.com/isaacHagoel/svelte-dnd-action), [npm](https://www.npmjs.com/package/svelte-dnd-action).

Its `use:dndzone` action takes an `items` array and emits `consider`/`finalize`; the application updates its array from the event detail. It supports horizontal/vertical/arbitrary shapes, nested zones, cross-zone typed drops, copy-on-drag, handles, animations, scrolling and touch. It has no external dependencies, TypeScript event generics, and MIT licensing. Sources: [README](https://github.com/isaacHagoel/svelte-dnd-action), [release notes](https://github.com/isaacHagoel/svelte-dnd-action/blob/master/release-notes.md).

The Svelte 5 story is “works” rather than “runes-native.” Release notes document a fix for Svelte 5 runes `$state` arrays in 0.9.59, a warning to skip 0.9.58 for `$state` users, and Svelte 5 event-handler documentation in 0.9.57. The maintainer closed a Svelte 5 event-syntax issue saying the library works with Svelte 5; its public API remains event-based and the README still starts from a Svelte 3 prerequisite. Sources: [release notes](https://github.com/isaacHagoel/svelte-dnd-action/blob/master/release-notes.md), [issue #624](https://github.com/isaacHagoel/svelte-dnd-action/issues/624).

Accessibility is advertised as fully accessible (beta), with keyboard support, ARIA attributes and assistive instructions. This is stronger out of the box than SortableJS, but the “beta” qualifier and legacy event API merit an accessibility regression test in the DHC app. It is a good fallback if sveltednd fails a real nested-list or mobile spike.

### 6. SortableJS — mature pointer-first option, not the default

SortableJS is MIT-licensed, framework-agnostic and currently **v1.15.7** on npm (update date 2026-02-11). The official README documents same-list and cross-list dragging, touch devices, handles, selectable text, animation, auto-scroll, nested sortables, MultiDrag and Swap plugins. It exposes `new Sortable(element, options)` and a modular build for cherrypicking plugins. Sources: [GitHub README](https://github.com/SortableJS/Sortable), [npm](https://www.npmjs.com/package/sortablejs).

It can be wrapped in a Svelte action that constructs on mount and calls `destroy` on teardown; data synchronization must be handled from Sortable callbacks. TypeScript definitions are provided through `@types/sortablejs`, not a Svelte-native typed API. The official README does not document keyboard reordering, ARIA behavior, screen-reader announcements or focus management. Thus it is attractive for a simple touch-enabled list but a poor default for member/operator inventory UI unless DHC builds the full keyboard and announcement layer. SSR still requires DOM-only initialization. No official numeric bundle size was found.

### 7. dnd-kit — do not choose yet without a spike

The current official repository has evolved beyond its historical React-only reputation: it advertises a framework-agnostic core (`@dnd-kit/abstract`), DOM layer (`@dnd-kit/dom`), and adapters for vanilla, React, Vue, Svelte and Solid, including `@dnd-kit/svelte`. It lists support for lists, grids, multiple containers, nesting, variable sizes, virtualization, pointer/mouse/touch/keyboard sensors, ARIA attributes, screen-reader instructions and live regions. The repository is MIT licensed. Source: [official GitHub README](https://github.com/clauderic/dnd-kit).

However, the primary sources available for this research do not establish a stable released Svelte adapter version, peer-dependency contract, Svelte 5/runes examples, or release cadence comparable to the candidates above. Treat the new architecture as promising, not as a proven dependency for this repo. Do not install a historical React `@dnd-kit/*` wrapper in Svelte; only consider it after verifying the exact package's npm release, Svelte adapter docs and SSR behavior in a disposable spike.

### 8. Browser API and excluded candidates

The native HTML Drag and Drop API is available without a dependency and exposes `dragstart`, `dragover`, `drop`, `dragend`, `DataTransfer`, draggable elements and drop targets. MDN notes that arbitrary elements need `draggable="true"`, transferred JavaScript objects must be serialized (or represented as `File`), and drag events are mouse-derived DOM events. It supplies no sortable-list model, touch abstraction, keyboard reorder flow, animation, collision algorithm or screen-reader announcements. It is appropriate for a small file-upload/drop target, not the dashboard's likely sortable/nested interactions. Source: [MDN HTML Drag and Drop API](https://developer.mozilla.org/en-US/docs/Web/API/HTML_Drag_and_Drop_API).

No convincing, maintained primary-source case was found during this search for `svelte-dnd` forks or a `neosvelte-dnd` rewrite that should outrank the candidates above. Avoid selecting an abandoned Svelte 3/4-only package merely because an old tutorial shows a convenient component API; require a current repository, explicit peer dependency and Svelte 5 test/example evidence.

## Recommendation

Adopt **`@thisux/sveltednd` as the first library to prototype**, behind a small DHC-owned adapter/component boundary. It is the closest match to Svelte 5.56.8: native runes examples, Svelte 5 peer dependency, typed actions, component attachments, cross-container/grid/nested primitives, touch support and an explicit keyboard/screen-reader feature set. Keep the application authoritative over `$state` arrays and persist only the final domain reorder; do not treat library drag state as server truth.

Before production adoption, spike: (1) shadcn-svelte card/list composition; (2) nested container/item moves; (3) keyboard and screen-reader announcements; (4) touch scrolling versus drag delay; (5) SvelteKit SSR/build and hydration; (6) optimistic reorder rollback on Phoenix failure. If any of those expose gaps, choose **Atlassian Pragmatic Drag and Drop** as the second choice when the team is willing to own the accessibility and sortable behavior. Choose `svelte-dnd-action` instead when ready-made nested sortable behavior and mature Svelte-specific ergonomics outweigh its older event API and `$state` compatibility history.

## What not to pick

- Do not pick a React-only historical dnd-kit wrapper or React rendering package. The current dnd-kit repo is worth revisiting, but verify the exact new Svelte package first.
- Do not pick an abandoned Svelte 3/4-only component/fork without current peer dependencies and Svelte 5 tests.
- Do not use SortableJS as the default for accessible inventory/loan workflows unless DHC implements and tests non-pointer controls, announcements and focus restoration.
- Do not hand-roll the native API for sortable/nested/kanban behavior; the browser API lacks the interaction and accessibility layers this dashboard will need.

## Open questions that could change the choice

1. Do users need keyboard-only movement with arbitrary destinations, or are explicit “move above/below/container” menu actions acceptable? The answer changes the accessibility implementation and favors either sveltednd or Atlassian's explicit-controls model.
2. Will inventory containers be deeply nested or virtualized at large scale? Test sveltednd first; Atlassian's low-level and virtualization-friendly model may win.
3. Must a kanban board support files/external drops, multi-select, or highly custom collision rules? Atlassian or the current dnd-kit architecture may be a better fit.
4. What mobile gestures are required—long-press while preserving page scroll, or immediate pointer drag? Validate on iOS and Android hardware.
5. Does the app require Cloudflare Workers/no-DOM execution in any shared module? Keep all chosen library initialization in client actions/mount code and verify the package's export conditions.

## Sources

- [@thisux/sveltednd GitHub README](https://github.com/thisuxhq/sveltednd)
- [@thisux/sveltednd npm package](https://www.npmjs.com/package/@thisux/sveltednd)
- [svelte-dnd-action README](https://github.com/isaacHagoel/svelte-dnd-action)
- [svelte-dnd-action release notes](https://github.com/isaacHagoel/svelte-dnd-action/blob/master/release-notes.md)
- [svelte-dnd-action Svelte 5 issue #624](https://github.com/isaacHagoel/svelte-dnd-action/issues/624)
- [Atlassian Pragmatic Drag and Drop core docs](https://atlassian.design/components/pragmatic-drag-and-drop/core-package)
- [Atlassian Pragmatic Drag and Drop accessibility guidelines](https://atlassian.design/components/pragmatic-drag-and-drop/accessibility-guidelines/)
- [Atlassian Pragmatic Drag and Drop GitHub](https://github.com/atlassian/pragmatic-drag-and-drop)
- [Atlassian Pragmatic Drag and Drop npm](https://www.npmjs.com/package/@atlaskit/pragmatic-drag-and-drop)
- [SortableJS GitHub README](https://github.com/SortableJS/Sortable)
- [SortableJS npm](https://www.npmjs.com/package/sortablejs)
- [dnd-kit official GitHub README](https://github.com/clauderic/dnd-kit)
- [MDN HTML Drag and Drop API](https://developer.mozilla.org/en-US/docs/Web/API/HTML_Drag_and_Drop_API)
