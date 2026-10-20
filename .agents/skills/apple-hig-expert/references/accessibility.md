# Accessibility on macOS

Read live on 2026-10-20. Rubric IDs in parentheses. Neither Apple guidance nor a passing measurement proves the whole app is accessible.

## Contrast

Apple's Accessibility page lists the WCAG AA values that Accessibility Inspector uses:

| Text | Minimum ratio | Rubric ID |
| --- | ---: | --- |
| Up to 17 pt, not bold | 4.5:1 | `accessibility.contrast.text` |
| 18 pt or larger | 3:1 | `accessibility.contrast.large-text` |
| Bold, any size | 3:1 | `accessibility.contrast.large-text` |

Apple gives no separate number for symbols, control boundaries, or state indicators. Use WCAG 2.2 SC 1.4.11 (3:1) and cite it as WCAG (`accessibility.contrast.non-text`).

- Check every state against its rendered background, in light and dark appearance.
- Over a material or Liquid Glass, sample the least favorable content behind it, then retest with Reduce Transparency.
- If default colors do not meet the minimum, provide a higher-contrast scheme when Increase Contrast is on (`accessibility.contrast.increase-contrast`). Prefer system colors, which already adapt.
- Never use color alone; add a shape, symbol, or text (`accessibility.color.independence`).

## Control size and spacing

| Platform | Default | Minimum |
| --- | --- | --- |
| macOS | 28 by 28 pt | 20 by 20 pt |

The tool fails a macOS hit region below 20 by 20 pt and flags one below 28 by 28 pt as advice (`accessibility.target.macos`). Measure the hit region, not the visible glyph. Apple's Buttons page states a general 44 by 44 pt hit region; for macOS pointer input this skill uses the platform-specific table above and says so.

Space between controls matters as much as size. Apple suggests about 12 pt around bezeled controls and 24 pt around borderless ones. In a dense layout, verify that adjacent targets are still easy to tell apart and hit (`accessibility.target.spacing`).

## Text

macOS has no Dynamic Type. Use text styles, stay at or above 10 pt (13 pt default), and avoid thin weights at small sizes. Test long values and localization for clipping and overlap (`accessibility.text.size`).

## VoiceOver

- Every control and meaningful image has a label that names its purpose; decorative images are hidden. Expose role, value, and state (`accessibility.voiceover.labels`). An icon-only toolbar or menu bar item always needs an accessibility label.
- Use headings and grouping so VoiceOver order follows the visual hierarchy. Announce important changes, such as a new worst finding (`accessibility.voiceover.navigation`).
- Make charts and status summaries readable as text.

## Keyboard and other inputs

Support Full Keyboard Access for every task, keep standard shortcuts, and do not override system shortcuts. Label elements so Voice Control can target them. Test Switch Control where practical (`macos.keyboard.shortcuts`).

## Display settings and motion

- Reduce Motion: remove or replace automatic and repeating animation, zooms, depth changes, and blur transitions; prefer fades (`accessibility.motion.reduced-motion`).
- Reduce Transparency: content stays legible and distinct (`accessibility.transparency.reduced`).
- Avoid views that dismiss on a timer. State any deliberate time limit in plain words (`accessibility.cognitive.timing`).

## Evidence levels

Record platform and OS version, appearance, settings, input, task, expected and observed result, and the evidence path.

- `measured`: tool output, Accessibility Inspector audit, or another reproducible result.
- `observed`: a named task done in the running app with the relevant setting or assistive technology on.
- `needs device test`: inferred from source or a static screenshot. A screenshot cannot prove reading order, focus movement, spoken output, or hit region.
- `assumption`: stated but not checked.

## Sources (read 2026-10-20)

- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple HIG: VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover)
- [Apple HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Apple HIG: Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Apple HIG: Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
- [Apple HIG: Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices)
- [WCAG 2.2: Non-text Contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html)
