# Little CI brand art

Little CI's mascot is the server-box runner: a warm white box head with three side vents, a status panel of two dots and three slots, the family's black ribbed turtleneck, on a mint circle (#D7EBE1) over Paper (#FBFAF7).

On October 29, 2026 the mascot was redrawn in the style of Little Worker's new character cast (Lou's character sheet): clean dark line art, soft flat colour with one gentle shade, a big head, expressive glossy eyes, white gloves and sneakers, and a thin Paper edge round the figure. Same concept, same colours. The first, black-and-white ink version is in git history.

## Files

| File | Size | Use |
| --- | --- | --- |
| `icon.png` | 1024x1024 | Square app icon, edge to edge |
| `icon-macos.png` | 1024x1024 | The icon in an 824 px rounded square (radius 185) on a transparent canvas, like the sibling apps |
| `icon.icns` | 16 to 1024 | Menu bar app icon (`app/scripts/build-app.sh` copies it). 16 and 32 px use `masters/icon-small-tight.png` |
| `banner.png` | 1536x768 | README banner |
| `social-preview.png` | 1280x640 | GitHub social preview (Settings, General, Social preview) |

`masters/` holds the native art: `icon`, `icon-small`, `icon-dark`, `walk`, `wave` and `mark` (head only, for a lockup). `masters/prompt.md` is the exact request.

## How it was made

Codex CLI image generation (`codex exec`, the built-in image tool) on the M4, with three references attached: Lou's character sheet for the style, and the old icon and banner for the concept. The banner and social preview keep the old wordmark and tagline pixels and put the new walking runner on the same mint circle. The icon grid, the tight small icon and the `.icns` (made with `iconutil`, as in Little Mac Stats' `scripts/create_app_icon.sh`) were made from the masters with a script. Nothing was retouched by hand.
