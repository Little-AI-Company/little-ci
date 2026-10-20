# Visual design on macOS

Read live on 2026-10-20. Rubric IDs in parentheses. The project profile wins on conflict.

## Liquid Glass and materials (`appearance.materials.liquid-glass`)

Apple's current design language uses two material kinds: Liquid Glass for the functional layer (controls and navigation that float above content, such as toolbars, sidebars, popovers, and menus) and standard materials for structure inside the content layer.

1. **Let standard components supply it.** SwiftUI and AppKit bars, sidebars, sheets, popovers, menus, and controls adopt Liquid Glass when built with the current SDK. Prefer them over custom effects.
2. **Keep it out of the content layer.** Use standard materials or plain backgrounds for content. The exception is transient controls such as a slider or toggle knob that turns glassy while in use.
3. **Use custom glass sparingly.** `glassEffect(_:in:)` (SwiftUI) or `NSGlassEffectView` (AppKit) only on the most important custom functional element. Overuse distracts from content.
4. **Choose the variant by background.** `regular` blurs and adjusts luminosity for legibility and is the default for text-heavy components like popovers and sidebars. `clear` is only for components over rich media; it may need a dimming layer. There is no thin/thick hierarchy for Liquid Glass; those names belong to standard materials.
5. **Remove custom backgrounds on bars and popovers.** Custom backgrounds or visual effect views in toolbars, split views, popovers, and menu bar extra windows can interfere with Liquid Glass and scroll edge effects.
6. **Test the adaptations.** People can pick a preferred Liquid Glass look in System Settings, and Reduce Transparency, Increase Contrast, and Reduce Motion change the material. Test each, in both appearances, over varied content.

On macOS, standard materials have designated purposes; choose them by meaning, not by the color they appear to give. Use vibrant system colors on top of materials. macOS offers behind-window and within-window blending.

## Color (`appearance.color.semantics`)

- Use the macOS dynamic system colors for their documented roles: `labelColor` through `quaternaryLabelColor` for text hierarchy, `separatorColor`, `controlAccentColor`, `selectedContentBackgroundColor`, `windowBackgroundColor`, and the rest. In SwiftUI, prefer `.primary`, `.secondary`, `.tint`, and semantic styles. Never hard-code their values or give them new meanings.
- One color, one meaning. Status color always comes with a shape or text (`accessibility.color.independence`).
- Respect the accent color people choose. A fixed sidebar icon color is only for icons whose color carries meaning.
- Apply color sparingly on Liquid Glass and on text or symbols placed on it.
- Provide light, dark, and increased-contrast variants for any custom color.

## Dark Mode (`appearance.dark-mode`)

Support both appearances and do not add an app-only appearance setting. Use system label colors and system text views. Check contrast in both appearances. With the graphite accent, macOS tints window backgrounds from the desktop picture; custom neutral backgrounds can include slight transparency to pick this up.

## Typography (`appearance.typography.text-styles`)

- SF Pro is the macOS system font. macOS does not support Dynamic Type.
- macOS text styles: Large Title 26, Title 1 22, Title 2 17, Title 3 15, Headline 13 bold, Body 13, Callout 12, Subheadline 11, Footnote 10, Caption 1 and 2 at 10 pt. Default body is 13 pt; the minimum is 10 pt.
- Prefer Regular, Medium, Semibold, or Bold; avoid Ultralight, Thin, and Light at small sizes.
- Use few typefaces. Use monospaced digits (`.monospacedDigit()`) where numbers update in place, and SF Mono only for code-like content.
- To match standard controls in AppKit, use the system font variants (`menuFont`, `labelFont`, `controlContentFont`, and so on).

## SF Symbols (`appearance.sf-symbols.usage`)

Apple released the SF Symbols 8 beta at WWDC26. Symbols match the weight of adjacent San Francisco text and come in small, medium, and large scales. Choose a rendering mode (monochrome, hierarchical, palette, multicolor) that works in every context, including the tinted menu bar, where only template rendering is reliable. Use variable color for changing values, not depth. Animate symbols only with a clear purpose; this project forbids repeating effects. Give custom symbols text labels.

## Layout (`appearance.layout.hierarchy`)

Order content by importance, align for scanning, indent for hierarchy, group related items, use progressive disclosure, and make controls look different from content. Apple sets no universal spacing grid; use system spacing and consistent values. On macOS, avoid critical content at the bottom of a window and respect safe areas around the camera housing.

## Motion (`appearance.motion.purposeful`)

Add motion only with a purpose, keep it brief and precise, never make it the only carrier of information, and generally avoid motion on interactions that happen often. Let people cancel motion. See the project profile for the ban on continuously repainting views.

## Sources (read 2026-10-20)

- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Icons](https://developer.apple.com/design/human-interface-guidelines/icons)
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [What's new in design](https://developer.apple.com/design/whats-new/)
