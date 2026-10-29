Use the built-in image generation tool (image_gen) to make SIX new images, one tool call per image. Before drawing, open and look at every attached reference with view_image: `ref-style-lou.png`, `ref-old-icon.png`, `ref-old-banner.png`.

## What this is

The Little AI Company has a family of small products. Each has a mascot: a little character whose head is an everyday object, wearing the family's black ribbed turtleneck. Until today they were drawn in flat black-and-white ink (see `ref-old-icon.png` and `ref-old-banner.png`). The company's main cast has just been redrawn in a new illustrated style (see `ref-style-lou.png`, the character sheet for Lou, whose head is a TV). Redraw THIS product's mascot in the new style. Same concept, same object head, same accent colour, same black turtleneck body: only the drawing style changes.

## The new style (match `ref-style-lou.png` exactly)

- Clean, confident dark line art (about #111), medium-heavy, round line ends. Not thick marker ink.
- Soft flat colour fills with at most one gentle soft shade (a light cel shadow on the side of the head and under the chin). No gradients beyond that, no glossy 3D, no texture, no glow.
- Cute proportions with a BIG head: the object head is about as tall as the whole body below it, like Lou. Short body, short legs.
- The face is expressive in the same way as Lou's face: two tall glossy black oval eyes with a small white highlight, small soft blush marks, and a friendly smile (open with a little pink tongue for happy poses, closed calm smile at rest).
- Body: black ribbed turtleneck sweater (#1A1A1A with soft dark grey shading), plain white cartoon gloves (puffy, like Lou's hands), simple white sneakers with a dark outline when the feet show.
- A thin line of cream Paper (#FBFAF7) runs round the whole figure, just outside its dark outline.
- Background: warm cream Paper #FBFAF7. One flat soft accent circle behind the character in this product's colour (below). No other shapes.
- Lots of empty space. No sparkles, no stars, no confetti, no motion lines, no props, no text, no letters, no logos, no Apple logo.

## This product: Little CI

Little CI runs GitHub Actions runners on your own Mac. Its mascot (see the old drawings) has a head that is a small server box:
- Head: a white/cream rounded cube seen from slightly above and to the left, so the front face and the left side and top show. On the front, top right: three short dark horizontal vent slots and two small dark dots beside them (a status light panel). On the left side: three dark vertical vent slots. The face sits on the front of the box, a little below the middle. Keep the vents and dots: they are the brand details.
- Box colour: warm white (#FFF9F0) with a soft light grey-cream shade (#E9E3D8) on the left side and top.
- Accent circle colour: soft mint #D7EBE1. Muted deep mint for the dark icon: #2F4A3F.

## Outputs (save exactly these file names in the current folder, PNG)

Draw the same character in all six, on model with each other. After generating each one, copy it from ~/.codex/generated_images/ into this folder with the exact name.

1. `icon.png`, square 1024x1024: the app icon. Head and shoulders (the object head plus the turtleneck collar and shoulders, cut by the bottom edge) centered on the accent circle, calm closed smile, facing the viewer. Same framing as `ref-old-icon.png`: the head fills about 60 percent of the width. Edge-to-edge square, no rounded corners, no text. The head's brand details (listed above) must stay readable at 64x64.
2. `icon-small.png`, square 1024x1024: for 16 to 32 pixels. Only the head (no body), filling about 70 percent of the square, on the accent circle over Paper. Thicker lines, bigger eyes, fewer details; keep only the brand details listed above.
3. `icon-dark.png`, square 1024x1024: the same drawing as `icon.png` on a warm dark field #2B2A28 with a muted deep version of the accent circle (given above). The head keeps its light colours. The black turtleneck keeps its thin Paper edge so it separates from the dark field.
4. `walk.png`, square 1024x1024: full body, walking cheerfully to the right in three-quarter view, one arm swinging forward, happy open smile, on the accent circle (the circle about 80 percent of the square, the figure inside it with its feet near the circle's bottom). Whole figure visible with margin all round. Paper background.
5. `wave.png`, square 1024x1024: full body, standing facing the viewer, waving hello with the right hand raised, happy open smile, on the accent circle. Whole figure visible with margin all round. Paper background.
6. `mark.png`, square 1024x1024: only the head (no body, no circle) facing the viewer, calm smile, centered on plain Paper #FBFAF7, filling about 75 percent of the square. This is the small logo mark that sits beside the product name.

After saving all six, view each file to check it exists, has no text or stray shapes, and matches the others. Reply with the six paths and their pixel sizes.
