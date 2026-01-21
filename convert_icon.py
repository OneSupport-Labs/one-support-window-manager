from PIL import Image
import os

src = r"C:/Users/jhpark/.gemini/antigravity/brain/1a54c548-7461-4046-ad71-f9a194170e67/uploaded_image_1767160167561.png"
dst1 = r"e:\dev\rustdesk-controller-window\res\icon.ico"
dst2 = r"e:\dev\rustdesk-controller-window\flutter\windows\runner\resources\app_icon.ico"

try:
    img = Image.open(src)
    # Generate ICO with multiple sizes for best quality on Windows
    sizes = [(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)]
    img.save(dst1, format='ICO', sizes=sizes)
    print(f"Saved {dst1}")
    img.save(dst2, format='ICO', sizes=sizes)
    print(f"Saved {dst2}")
    print("Converted successfully")
except Exception as e:
    print(f"Error: {e}")
    exit(1)
