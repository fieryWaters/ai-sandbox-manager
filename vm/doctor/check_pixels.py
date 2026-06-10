"""Assert a screenshot contains the doctor's magenta test page.

Usage: check_pixels.py IMAGE [MIN_PIXELS]
"""

import sys

from PIL import Image

image = Image.open(sys.argv[1]).convert("RGB")
minimum = int(sys.argv[2]) if len(sys.argv) > 2 else 10000

magenta = 0
for r, g, b in image.getdata():
    if r > 200 and g < 80 and b > 200:
        magenta += 1

if magenta < minimum:
    print(f"expected magenta test page pixels, found {magenta}", file=sys.stderr)
    sys.exit(1)
print(f"magenta pixels: {magenta}")
