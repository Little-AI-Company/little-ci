# macOS platform guidance

Read live on 2026-10-20. Summaries of Apple's guidance; rubric IDs in parentheses. Project rules in [little-ci-macos-profile.md](little-ci-macos-profile.md) win on conflict.

## The Mac context

People sit 1 to 3 feet from a large display, run several apps at once, use a precise pointer and a keyboard, and switch between active and inactive windows often. Use the space to show more content with fewer nested levels and less modality, while keeping density comfortable. Let people resize, hide, and move windows. Support keyboard-only work and personalization where it helps.

## Menu bar extras

- An extra is an icon at the trailing end of the menu bar that exposes app functions even when the app is not frontmost. The system hides extras when space is short, so never depend on yours being visible (`macos.menu-bar-extra.not-sole-path`).
- Use an SF Symbol or a template icon made of black and clear areas. The system tints it for light and dark menu bars and for the selected state. The menu bar is 24 pt tall (`macos.menu-bar-extra.symbol`).
- Show a menu on click. Use a popover-like window only when the functions are too complex for a menu. SwiftUI's `MenuBarExtra` `.window` style is Apple's option for complex or data-rich extras; record why the content needs it (`macos.menu-bar-extra.menu-first`).
- People decide whether the extra is shown. A menu-bar-only app (`LSUIElement`) quits when people remove its extra, so document how to get it back (`macos.menu-bar-extra.user-control`).
- Offer the same functions another way too. Apple suggests a Dock menu; an agent app has no Dock icon, so use a window.

## Menus

Title-style labels without articles, an ellipsis when more input follows, dimmed items when unavailable, frequent items first, related items grouped, few and shallow submenus. Since June 2026, Apple asks for menu item icons only when an icon clearly represents the item, and for icons on all items in a group or none (`content.menus.labels`).

## Windows

- Windows resize fluidly and keep state. Use the system appearances for main, key, and inactive windows and avoid custom window UI (`macos.windows.behavior`).
- Give each window a useful, concise title, not only the app name.
- Do not put critical controls or information at the bottom of a window or sidebar; a window can extend below the display (`macos.windows.bottom-edge`).
- Panels are for quick controls or inspector content related to the main work; prefer standard panels over HUD style.

## Sidebars and split views

No more than two levels of hierarchy, familiar symbols, icon colors only with a clear purpose (updated June 2026), persistent highlight of the selection, and the option to hide the sidebar. Set sensible minimum and maximum pane sizes and prefer the thin divider (`macos.sidebar.structure`).

## Toolbars

Few, deliberate items; standard components; system symbols without borders; an accessibility label on every icon; items grouped by function; consistent placement. In a regular app, every toolbar item is also a menu bar command. Do not add custom backgrounds or tints that fight Liquid Glass (`macos.toolbar.items`).

## Lists and tables

Succinct row text, a way to read clipped text, descriptive column headings, click-to-sort when useful, resizable columns, alternating rows for wide tables, and an outline view for hierarchy. Liquid Glass styles give lists and forms larger rows; see the density rule in the project profile (`macos.lists-tables.behavior`).

## Controls

- Switches and checkboxes belong in the window body, not the frame. Use a switch for an emphasized setting, a mini switch for one row in a grouped form, a checkbox for a hierarchy of settings, radio buttons for a few exclusive options (`macos.controls.toggles`).
- Push buttons that open another window or view get a trailing ellipsis. Use a prominent style, not a larger size, for the preferred action. Custom buttons need a press state.
- Alerts are rare: for consequential actions that cannot be undone, with a direct title and action-named buttons (`macos.alerts.use`).

## Progress and loading

Show content as soon as possible, let people do other things while work runs, prefer determinate progress, keep it in one place, and let people halt work when feasible. Apple prefers a spinner for background work on macOS; this project replaces animated indicators with static status (`macos.progress.honesty`).

## Keyboard

Keep standard shortcuts (Command-Q, Command-W, Command-Comma for Settings, and so on) with their standard meaning. Add custom shortcuts only for frequent commands. Every task must work with Full Keyboard Access, and a shown shortcut must work (`macos.keyboard.shortcuts`).

## Settings

If the app has settings, open them from the App menu Settings item (Command-Comma) in a regular app, keep the settings toolbar fixed, title the window after the current pane, and restore the last pane. Do not duplicate system settings such as appearance.

## Sources (read 2026-10-20)

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
- [SwiftUI MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [Dock menus](https://developer.apple.com/design/human-interface-guidelines/dock-menus)
- [Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers)
- [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
- [Panels](https://developer.apple.com/design/human-interface-guidelines/panels)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)
- [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)
- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)
- [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
- [Loading](https://developer.apple.com/design/human-interface-guidelines/loading)
- [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
- [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
