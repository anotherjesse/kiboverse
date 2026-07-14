"""robot_face.py – Raspberry Pi‑driven 240×320 ILI9341 face renderer.

Key fixes in this revision
--------------------------
* **Back‑light always on via plain GPIO18** (no pwmio). Turns OFF on `Ctrl‑C`.
* **Image rotated 180 °** so the face is upright on your current wiring.
"""

from __future__ import annotations

import queue, random, threading, time
from typing import Tuple

from PIL import Image, ImageDraw

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
            if nat_blink_timer > random.uniform(6,9):
                self._blink_req, self._blink_t = "both", 0.0
                nat_blink_timer = 0.0
            blinking = False
            blink_eye = "both"
            if self._blink_req and self._blink_t < 0.3:
                blinking, blink_eye = True, self._blink_req
            elif self._blink_req and self._blink_t >= 0.3:
                self._blink_req = None
            img = Image.new("RGB", (w, h), self.bg_color)
            draw = ImageDraw.Draw(img)
            dx = int(self._look_h * (self.eye_r - self.pupil_r - 2))
            dy = int(self._look_v * (self.eye_r - self.pupil_r - 2))
            for idx,(cx,cy) in enumerate(((w//2-eye_off,eye_y),(w//2+eye_off,eye_y))):
                side = "left" if idx==0 else "right"
                if blinking and (blink_eye in ("both", side)):
                    draw.line((cx-self.eye_r, cy, cx+self.eye_r, cy), fill=self.eye_white, width=4)
                    continue
                draw.ellipse((cx-self.eye_r, cy-self.eye_r, cx+self.eye_r, cy+self.eye_r), fill=self.eye_white)
                draw.ellipse((cx-self.iris_r+dx, cy-self.iris_r+dy, cx+self.iris_r+dx, cy+self.iris_r+dy), fill=self.iris_color)
                draw.ellipse((cx-self.pupil_r+dx, cy-self.pupil_r+dy, cx+self.pupil_r+dx, cy+self.pupil_r+dy), fill=self.pupil_color)
            mx0, mx1 = w//4, 3*w//4
            my = int(h*0.7)
            mouth_h = h//4
            if self._expression == "happy":
                draw.arc((mx0, my-mouth_h//2, mx1, my+mouth_h//2), 200, 340, fill=self.eye_white, width=4)
            elif self._expression == "sad":
                draw.arc((mx0, my-mouth_h//2, mx1, my+mouth_h//2), 20, 160, fill=self.eye_white, width=4)
            else:
                draw.line((mx0, my, mx1, my), fill=self.eye_white, width=4)
            # rotate and display
            self.display.image(img.rotate(ROTATE_DEG))
            time.sleep(self.dt)

face = RobotFace()

if __name__ == "__main__":
    try:
        while True:
            random.choice([
                lambda: face.look(random.uniform(-1,1), random.uniform(-0.5,0.5)),
                lambda: face.set_expression(random.choice(["neutral","happy","sad"])),
                lambda: face.blink(random.choice(["both","left","right"])),
            ])()
            time.sleep(random.uniform(1.0,2.5))
    except KeyboardInterrupt:
        face.stop()

