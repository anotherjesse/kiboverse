"""robot_face.py – Raspberry Pi‑driven 240×320 ILI9341 face renderer.

Key fixes in this revision
--------------------------
* **Back‑light always on via plain GPIO18** (no pwmio). Turns OFF on `Ctrl‑C`.
* **Image rotated 180 °** so the face is upright on your current wiring.
"""

from __future__ import annotations

import queue, random, threading, time
from typing import Tuple

from PIL import Image, ImageDraw, ImageFont

# Physical pixel dimensions
SCREEN_W, SCREEN_H = 240, 320
ROTATE_DEG = 90         

# ---------------- hardware init -----------------
import board, busio, digitalio
from adafruit_rgb_display import ili9341

spi = busio.SPI(board.SCK, board.MOSI, board.MISO)
cs  = digitalio.DigitalInOut(board.CE0)
dc  = digitalio.DigitalInOut(board.D25)
rst = digitalio.DigitalInOut(board.D24)

DISPLAY = ili9341.ILI9341(
    spi, cs=cs, dc=dc, rst=rst,
    baudrate=40_000_000,
    width=SCREEN_W, height=SCREEN_H,
)

# Back‑light simple ON/OFF
_backlight = digitalio.DigitalInOut(board.D18)
_backlight.direction = digitalio.Direction.OUTPUT
_backlight.value = True     # ON

# -------------------------------------------------
CMD_LOOK, CMD_EXPR, CMD_BLINK = range(3)

class RobotFace:
    def __init__(
        self,
        display=DISPLAY,
        *,
        eye_radius:int=36,
        pupil_radius:int=14,
        iris_color:Tuple[int,int,int]=(0,200,255),
        pupil_color:Tuple[int,int,int]=(0,0,0),
        eye_white:Tuple[int,int,int]=(255,255,255),
        bg_color:Tuple[int,int,int]=(0,0,32),
        fps:int=40,
    ) -> None:
        self.display = display
        self.eye_r = eye_radius
        self.pupil_r = pupil_radius
        self.iris_r = int(self.eye_r*0.6)
        self.iris_color, self.pupil_color = iris_color, pupil_color
        self.eye_white, self.bg_color = eye_white, bg_color
        self.dt = 1.0 / fps
        self._look_h = self._look_v = 0.0
        self._expression = "neutral"
        self._blink_req = None
        self._blink_t = 0.0
        self.q: "queue.Queue[tuple[int,object]]" = queue.Queue()
        self._running = True
        self._start_time = time.monotonic()  # Track when we started
        self._eye_style = "oval"  # Start with oval eyes
        self._y_offset = 0  # Vertical offset for the entire bunny (starts at 0)
        self._show_text = False  # Flag to control text display
        self._text_color_switch_time = 0  # Last time we switched text color
        self._text_is_red = True  # Start with red text
        
        # Try to import a font for text display
        try:
            self._font = ImageFont.load_default()
        except:
            self._font = None
            
        threading.Thread(target=self._loop, daemon=True).start()

    # ---------- API ----------
    def look(self, h:float, v:float=0.0):
        self.q.put((CMD_LOOK, (h, v)))
    def set_expression(self, e:str):
        self.q.put((CMD_EXPR, e))
    def blink(self, eye:str="both"):
        self.q.put((CMD_BLINK, eye))
    def stop(self):
        self._running = False
        _backlight.value = False  # turn off BL

    # ---------- render loop ----------
    def _loop(self):
        w, h = SCREEN_W, SCREEN_H
        eye_y = h//3
        eye_off = w//4
        pupil_max = self.eye_r - self.pupil_r - 2
        last = time.monotonic()
        nat_blink_timer = 0.0
        while self._running:
            # handle commands
            while not self.q.empty():
                cmd, data = self.q.get()
                if cmd == CMD_LOOK:
                    self._look_h, self._look_v = data  # type: ignore
                elif cmd == CMD_EXPR:
                    self._expression = str(data)
                elif cmd == CMD_BLINK:
                    self._blink_req, self._blink_t = str(data), 0.0
            now = time.monotonic()
            dt = now - last
            last = now
            nat_blink_timer += dt
            self._blink_t += dt
            
            # Check if we should change eye style based on elapsed time
            elapsed_time = now - self._start_time
            if elapsed_time > 23.0 and not self._show_text:
                # 7 seconds after the bunny starts moving downward (16+7=23)
                self._show_text = True
                self._text_color_switch_time = now  # Initialize the color switch timer
            
            # Check if we should switch text color (every 0.1 seconds)
            if self._show_text and now - self._text_color_switch_time >= 0.1:
                self._text_is_red = not self._text_is_red  # Toggle between red and white
                self._text_color_switch_time = now  # Reset the timer
            
            if elapsed_time > 16.0:
                # Start moving the bunny down slowly after 16 seconds
                # Increase the offset by a small amount each frame for a slow movement
                # Max offset is the screen height to ensure it eventually moves off-screen
                if self._y_offset < h:
                    self._y_offset += 4.0  # Increased from 1.5 to 4.0 for much faster movement
            
            if elapsed_time > 12.0 and self._eye_style != "x":
                self._eye_style = "x"
            elif elapsed_time > 8.0 and self._eye_style != "horizontal" and self._eye_style != "x":
                self._eye_style = "horizontal"
            elif elapsed_time > 3.0 and self._eye_style == "oval":
                self._eye_style = "vertical"
            
            if nat_blink_timer > random.uniform(6,9):
                self._blink_req, self._blink_t = "both", 0.0
                nat_blink_timer = 0.0
            blinking = False
            blink_eye = "both"
            if self._blink_req and self._blink_t < 0.3:
                blinking, blink_eye = True, self._blink_req
            elif self._blink_req and self._blink_t >= 0.3:
                self._blink_req = None
                
            # Create a blank image with the background color
            img = Image.new("RGB", (w, h), self.bg_color)
            draw = ImageDraw.Draw(img)
            
            # Setup dimensions and positions
            circle_radius = min(w, h) // 2.5  # Circle size for head
            circle_center_x = w // 2
            circle_center_y = int(h * 0.75) + int(self._y_offset)  # Apply vertical offset
            
            oval_width = circle_radius // 1.8  # Width for ears
            oval_height = circle_radius * 1.5  # Height for ears
            oval_bottom = circle_center_y - circle_radius // 2  # Position so 1/4 overlaps
            oval_top = oval_bottom - oval_height
            
            # Right ear position
            oval_center_x_right = circle_center_x + 35
            oval_left_right = oval_center_x_right - oval_width // 2
            oval_right_right = oval_center_x_right + oval_width // 2
            
            # Left ear position
            oval_center_x_left = circle_center_x - 35
            oval_left_left = oval_center_x_left - oval_width // 2
            oval_right_left = oval_center_x_left + oval_width // 2
            
            # Draw in proper order: brown ear first, then head, then white ear
            
            # 1. Draw left oval (brown ear) first so it appears behind the head
            draw.ellipse(
                (oval_left_left, oval_top, oval_right_left, oval_bottom),
                fill=(210, 180, 140)  # Light brown for left ear
            )
            
            # 2. Draw the white circle (head) next so it appears on top of the brown ear
            draw.ellipse(
                (circle_center_x - circle_radius, circle_center_y - circle_radius, 
                 circle_center_x + circle_radius, circle_center_y + circle_radius), 
                fill=(255, 255, 255)
            )
            
            # 3. Draw right oval (white ear) last
            draw.ellipse(
                (oval_left_right, oval_top, oval_right_right, oval_bottom),
                fill=(255, 255, 255)  # White like the head
            )
            
            # Eyes (black ovals that change to lines after 5 seconds)
            black_oval_height = oval_width // 2
            black_oval_width = oval_width // 3
            
            # Position for left eye
            black_oval_center_x_left = oval_center_x_left
            black_oval_center_y = oval_bottom
            
            # Position for right eye
            black_oval_center_x_right = oval_center_x_right
            
            # Draw eyes based on current style
            if self._eye_style == "oval":
                # Draw oval eyes
                # Left eye
                draw.ellipse(
                    (black_oval_center_x_left - black_oval_width//2, 
                     black_oval_center_y - black_oval_height//2,
                     black_oval_center_x_left + black_oval_width//2, 
                     black_oval_center_y + black_oval_height//2),
                    fill=(0, 0, 0)  # Black eye
                )
                
                # Right eye
                draw.ellipse(
                    (black_oval_center_x_right - black_oval_width//2, 
                     black_oval_center_y - black_oval_height//2,
                     black_oval_center_x_right + black_oval_width//2, 
                     black_oval_center_y + black_oval_height//2),
                    fill=(0, 0, 0)  # Black eye
                )
            elif self._eye_style == "vertical":
                # Draw vertical line eyes
                line_height = black_oval_height * 1.2  # Slightly taller than the ovals
                line_width = black_oval_width // 3  # Thinner than the ovals
                
                # Left eye line
                draw.rectangle(
                    (black_oval_center_x_left - line_width//2,
                     black_oval_center_y - line_height//2,
                     black_oval_center_x_left + line_width//2,
                     black_oval_center_y + line_height//2),
                    fill=(0, 0, 0)
                )
                
                # Right eye line
                draw.rectangle(
                    (black_oval_center_x_right - line_width//2,
                     black_oval_center_y - line_height//2,
                     black_oval_center_x_right + line_width//2,
                     black_oval_center_y + line_height//2),
                    fill=(0, 0, 0)
                )
            elif self._eye_style == "horizontal":
                # Draw horizontal line eyes
                line_width = black_oval_height * 1.2  # Wider than the ovals
                line_height = black_oval_width // 3  # Thinner than the ovals
                
                # Left eye line
                draw.rectangle(
                    (black_oval_center_x_left - line_width//2,
                     black_oval_center_y - line_height//2,
                     black_oval_center_x_left + line_width//2,
                     black_oval_center_y + line_height//2),
                    fill=(0, 0, 0)
                )
                
                # Right eye line
                draw.rectangle(
                    (black_oval_center_x_right - line_width//2,
                     black_oval_center_y - line_height//2,
                     black_oval_center_x_right + line_width//2,
                     black_oval_center_y + line_height//2),
                    fill=(0, 0, 0)
                )
            elif self._eye_style == "x":
                # X-shaped eyes
                # Size of the X
                x_size = black_oval_height * 0.8
                line_width = 3  # Width of the lines in the X
                
                # Left eye X
                # Draw first diagonal line (top-left to bottom-right)
                draw.line(
                    (black_oval_center_x_left - x_size//2, black_oval_center_y - x_size//2,
                     black_oval_center_x_left + x_size//2, black_oval_center_y + x_size//2),
                    fill=(0, 0, 0),
                    width=line_width
                )
                # Draw second diagonal line (bottom-left to top-right)
                draw.line(
                    (black_oval_center_x_left - x_size//2, black_oval_center_y + x_size//2,
                     black_oval_center_x_left + x_size//2, black_oval_center_y - x_size//2),
                    fill=(0, 0, 0),
                    width=line_width
                )
                
                # Right eye X
                # Draw first diagonal line
                draw.line(
                    (black_oval_center_x_right - x_size//2, black_oval_center_y - x_size//2,
                     black_oval_center_x_right + x_size//2, black_oval_center_y + x_size//2),
                    fill=(0, 0, 0),
                    width=line_width
                )
                # Draw second diagonal line
                draw.line(
                    (black_oval_center_x_right - x_size//2, black_oval_center_y + x_size//2,
                     black_oval_center_x_right + x_size//2, black_oval_center_y - x_size//2),
                    fill=(0, 0, 0),
                    width=line_width
                )
            
            # Add a small black dot (nose) positioned higher in the circle
            dot_radius = 4
            dot_center_y = circle_center_y - int(circle_radius * 0.3)
            
            draw.ellipse(
                (circle_center_x - dot_radius, dot_center_y - dot_radius,
                 circle_center_x + dot_radius, dot_center_y + dot_radius),
                fill=(0, 0, 0)  # Black dot
            )
            
            # Add light pink ovals to the left and right of the nose (horizontal orientation)
            pink_oval_width = black_oval_height  # Same height as black oval but horizontal
            pink_oval_height = black_oval_width  # Same width as black oval but horizontal
            
            # Right pink oval
            pink_oval_center_x_right = circle_center_x + int(circle_radius * 0.6)  # Far to the right
            pink_oval_center_y = dot_center_y  # Same height as nose
            
            # Left pink oval
            pink_oval_center_x_left = circle_center_x - int(circle_radius * 0.6)  # Far to the left
            
            # Draw right pink oval
            draw.ellipse(
                (pink_oval_center_x_right - pink_oval_width//2, 
                 pink_oval_center_y - pink_oval_height//2,
                 pink_oval_center_x_right + pink_oval_width//2, 
                 pink_oval_center_y + pink_oval_height//2),
                fill=(245, 160, 170)  # Slightly darker pink
            )
            
            # Draw left pink oval
            draw.ellipse(
                (pink_oval_center_x_left - pink_oval_width//2, 
                 pink_oval_center_y - pink_oval_height//2,
                 pink_oval_center_x_left + pink_oval_width//2, 
                 pink_oval_center_y + pink_oval_height//2),
                fill=(245, 160, 170)  # Slightly darker pink
            )
            
            # Draw the "bunny" text if needed
            if self._show_text:
                # Set text properties
                letters = ["B", "U", "N", "N", "Y"]
                text_color = (255, 0, 0) if self._text_is_red else (255, 255, 255)
                letter_size = 150  # Very large letters
                
                # Calculate letter positions and draw each letter separately
                if self._font:
                    try:
                        # Calculate spacing between letters
                        total_width = 0
                        letter_heights = []
                        
                        # First pass to measure all letters
                        for letter in letters:
                            if hasattr(draw, 'textbbox'):
                                # For newer PIL versions
                                bbox = draw.textbbox((0, 0), letter, font=self._font)
                                letter_width = bbox[2] - bbox[0]
                                letter_height = bbox[3] - bbox[1]
                            else:
                                # For older PIL versions
                                letter_width, letter_height = draw.textsize(letter, font=self._font)
                            
                            total_width += letter_width
                            letter_heights.append(letter_height)
                        
                        # Add some spacing between letters
                        spacing = 20
                        total_width += spacing * (len(letters) - 1)
                        
                        # Calculate starting position to center the whole text
                        start_x = (w - total_width) // 2
                        middle_y = h // 2
                        
                        # Second pass to draw each letter
                        current_x = start_x
                        for i, letter in enumerate(letters):
                            if hasattr(draw, 'textbbox'):
                                # For newer PIL versions
                                bbox = draw.textbbox((0, 0), letter, font=self._font)
                                letter_width = bbox[2] - bbox[0]
                                letter_height = bbox[3] - bbox[1]
                            else:
                                # For older PIL versions
                                letter_width, letter_height = draw.textsize(letter, font=self._font)
                            
                            # Center the letter vertically
                            letter_y = middle_y - letter_height // 2
                            
                            # Draw the letter
                            draw.text((current_x, letter_y), letter, fill=text_color, font=self._font)
                            
                            # Draw second letter (above)
                            draw.text((current_x, letter_y - letter_height - 10), letter, fill=text_color, font=self._font)
                            
                            # Draw third letter (below)
                            draw.text((current_x, letter_y + letter_height + 10), letter, fill=text_color, font=self._font)
                            
                            # Move to the next letter position
                            current_x += letter_width + spacing
                            
                    except Exception as e:
                        # If all else fails, just display the letters spaced evenly
                        letter_width = w // (len(letters) + 1)
                        for i, letter in enumerate(letters):
                            # Draw main letter
                            y_pos = h//2 - 75
                            x_pos = (i+1) * letter_width - 30
                            draw.text((x_pos, y_pos), letter, fill=text_color)
                            
                            # Draw second letter (above)
                            draw.text((x_pos, y_pos - 150), letter, fill=text_color)
                            
                            # Draw third letter (below)
                            draw.text((x_pos, y_pos + 150), letter, fill=text_color)
                else:
                    # No font available, just display the letters spaced evenly
                    letter_width = w // (len(letters) + 1)
                    for i, letter in enumerate(letters):
                        # Draw main letter
                        y_pos = h//2 - 75
                        x_pos = (i+1) * letter_width - 30
                        draw.text((x_pos, y_pos), letter, fill=text_color)
                        
                        # Draw second letter (above)
                        draw.text((x_pos, y_pos - 150), letter, fill=text_color)
                        
                        # Draw third letter (below)
                        draw.text((x_pos, y_pos + 150), letter, fill=text_color)
            
            # rotate and display
            self.display.image(img.rotate(ROTATE_DEG))
            time.sleep(self.dt)

face = RobotFace()

if __name__ == "__main__":
    try:
        # Initialize the servo controller
        from body import Body
        body_ctl = Body()
        
        # Start a thread to move servo 1 (sway) back and forth
        def servo_side_to_side():
            import time
            while True:
                # Move right
                body_ctl.move({1: 30}, 0.5)  # Move to 30 degrees
                time.sleep(0.6)
                # Move left
                body_ctl.move({1: 150}, 0.5)  # Move to 150 degrees
                time.sleep(0.6)
        
        import threading
        movement_thread = threading.Thread(target=servo_side_to_side, daemon=True)
        movement_thread.start()
        
        # Display the face
        while True:
            random.choice([
                lambda: face.look(random.uniform(-1,1), random.uniform(-0.5,0.5)),
                lambda: face.set_expression(random.choice(["neutral","happy","sad"])),
                lambda: face.blink(random.choice(["both","left","right"])),
            ])()
            time.sleep(random.uniform(1.0,2.5))
    except KeyboardInterrupt:
        face.stop()
        if 'body_ctl' in locals():
            body_ctl.stop()

