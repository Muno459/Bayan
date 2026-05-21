#!/usr/bin/env python3
"""
Generate a sleek app icon for Bayan - Quran learning app.
Design: Modern gradient with Arabic letter "ب" (Ba - first letter of Bayan)
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math
import os

OUTPUT_DIR = "/Users/mostafamahdi/Developer/Bayan/Bayan/Resources/Assets.xcassets/AppIcon.appiconset"
SIZE = 1024

def create_gradient(size, color1, color2, direction='diagonal'):
    """Create a gradient image."""
    img = Image.new('RGB', (size, size))
    pixels = img.load()

    for y in range(size):
        for x in range(size):
            if direction == 'diagonal':
                # Diagonal gradient from top-left to bottom-right
                ratio = (x + y) / (2 * size)
            elif direction == 'radial':
                # Radial gradient from center
                cx, cy = size / 2, size / 2
                dist = math.sqrt((x - cx) ** 2 + (y - cy) ** 2)
                max_dist = math.sqrt(cx ** 2 + cy ** 2)
                ratio = dist / max_dist
            else:
                ratio = y / size

            r = int(color1[0] * (1 - ratio) + color2[0] * ratio)
            g = int(color1[1] * (1 - ratio) + color2[1] * ratio)
            b = int(color1[2] * (1 - ratio) + color2[2] * ratio)
            pixels[x, y] = (r, g, b)

    return img

def add_rounded_corners(img, radius):
    """Add rounded corners to an image."""
    # Create a mask for rounded corners
    mask = Image.new('L', img.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, img.size[0], img.size[1]], radius=radius, fill=255)

    # Apply mask
    result = Image.new('RGBA', img.size, (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result

def create_bayan_icon():
    """Create the Bayan app icon."""

    # Colors - Emerald/Teal theme matching the app
    # Primary: #10B981 (emerald-500)
    # Darker: #047857 (emerald-700)
    # Accent: #34D399 (emerald-400)

    color_top = (16, 185, 129)      # Emerald 500
    color_bottom = (4, 120, 87)     # Emerald 700
    accent = (52, 211, 153)         # Emerald 400

    # Create base gradient
    img = create_gradient(SIZE, color_top, color_bottom, direction='diagonal')
    img = img.convert('RGBA')

    draw = ImageDraw.Draw(img)

    # Add subtle pattern/texture - concentric circles for depth
    for i in range(3):
        radius = SIZE // 2 - (i * 80) - 100
        if radius > 0:
            cx, cy = SIZE // 2, SIZE // 2
            circle_color = (255, 255, 255, 15 - i * 4)  # Very subtle white
            # Draw circle outline
            for angle in range(0, 360, 2):
                x = cx + radius * math.cos(math.radians(angle))
                y = cy + radius * math.sin(math.radians(angle))
                draw.ellipse([x-2, y-2, x+2, y+2], fill=circle_color)

    # Draw the Arabic letter "ب" (Ba) - stylized
    # Using a large, elegant representation

    # Try to load an Arabic font, fall back to drawing manually
    font_size = 500
    font = None

    # Common Arabic font paths on macOS
    arabic_fonts = [
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/GeezaPro.ttc",
        "/Library/Fonts/Al Nile.ttc",
        "/System/Library/Fonts/Supplemental/AmiriQuran.ttc",
        "/Library/Fonts/AmiriQuran-Regular.ttf",
    ]

    for font_path in arabic_fonts:
        if os.path.exists(font_path):
            try:
                font = ImageFont.truetype(font_path, font_size)
                break
            except:
                continue

    # The letter "ب" (Ba)
    letter = "ب"

    if font:
        # Get text bounding box
        bbox = draw.textbbox((0, 0), letter, font=font)
        text_width = bbox[2] - bbox[0]
        text_height = bbox[3] - bbox[1]

        # Center the letter
        x = (SIZE - text_width) // 2 - bbox[0]
        y = (SIZE - text_height) // 2 - bbox[1] - 40  # Slightly above center

        # Draw shadow
        shadow_offset = 8
        draw.text((x + shadow_offset, y + shadow_offset), letter,
                  font=font, fill=(0, 0, 0, 40))

        # Draw main letter in white
        draw.text((x, y), letter, font=font, fill=(255, 255, 255, 255))
    else:
        # Fallback: draw a stylized "B" shape if no Arabic font
        print("No Arabic font found, using geometric design")

        # Draw a geometric book/quran shape instead
        cx, cy = SIZE // 2, SIZE // 2

        # Open book shape
        book_width = 400
        book_height = 300

        # Left page
        draw.polygon([
            (cx - 20, cy - book_height//2),
            (cx - book_width//2, cy - book_height//2 + 30),
            (cx - book_width//2, cy + book_height//2 - 30),
            (cx - 20, cy + book_height//2),
        ], fill=(255, 255, 255, 240))

        # Right page
        draw.polygon([
            (cx + 20, cy - book_height//2),
            (cx + book_width//2, cy - book_height//2 + 30),
            (cx + book_width//2, cy + book_height//2 - 30),
            (cx + 20, cy + book_height//2),
        ], fill=(255, 255, 255, 240))

        # Spine
        draw.rectangle([cx - 20, cy - book_height//2, cx + 20, cy + book_height//2],
                      fill=(220, 220, 220, 255))

    # Add subtle inner glow/highlight at top
    highlight = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    for i in range(100):
        alpha = int(30 * (1 - i/100))
        highlight_draw.ellipse([
            SIZE//2 - SIZE//2 + i*3,
            -SIZE//2 + i*3,
            SIZE//2 + SIZE//2 - i*3,
            SIZE//4 - i*2
        ], fill=(255, 255, 255, alpha))

    img = Image.alpha_composite(img, highlight)

    # Save as PNG
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_path = os.path.join(OUTPUT_DIR, "AppIcon.png")

    # Convert to RGB for final save (iOS requires no alpha in app icons)
    final = Image.new('RGB', (SIZE, SIZE), (255, 255, 255))
    final.paste(img, mask=img.split()[3] if img.mode == 'RGBA' else None)
    final.save(output_path, 'PNG', quality=100)

    print(f"Created app icon: {output_path}")

    # Update Contents.json
    contents = '''{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}'''

    with open(os.path.join(OUTPUT_DIR, "Contents.json"), 'w') as f:
        f.write(contents)

    print("Updated Contents.json")

if __name__ == "__main__":
    create_bayan_icon()
