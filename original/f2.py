"""robot_face.py – threaded face renderer for a 240×320 ILI9341 screen on Raspberry Pi

* Features
  - Auto‑initialises SPI display + back‑light.
  - Renders eyeball ▸ iris ▸ pupil, with configurable iris colour.
  - Smooth blinks (~300 ms) and occasional natural blink.
  - `look()`, `blink()`, `set_expression()` thread‑safe controls.
  - Corrected hardware rotation (90° clockwise) so the face appears upright.

Run this file directly for a whimsical demo.
"""
from __future__ import annotations

import queue, random, threading, time
from typing import Tuple

from PIL import Image, ImageDraw

# ------------------------ hardware --------------------------
try:
    import board, busio, digitalio, pwmio
    from adafruit_rgb_display import ili9341

    _spi = busio.SPI(board.SCK, board.MOSI, board.MISO)
    _cs  = digitalio.DigitalInOut(board.CE0)
    _dc  = digitalio.DigitalInOut(board.D25)
    _rst = digitalio.DigitalInOut(board.D24)

    DISPLAY = ili9341.ILI9341(
        _spi, cs=_cs, dc=_dc, rst=_rst,
        baudrate=40_000_000,
        width=240, height=320,
        rotation=90,            # ⇢ face is upright on most breadboards
    )

    # full‑brightness back‑light (GPIO 18)
    try:
        pwmio.PWMOut(board.D18, frequency=1000, duty_cycle=65535)
    except Exception:
        pass
except (ImportError, RuntimeError):
    # headless fallback
    class _Dummy:
        def __init__(self, w=240, h=320):
            self.width, self.height = w, h
            self.frames = []
        def image(self, img):
            self.frames.append(img.copy())
    DISPLAY = _Dummy()

# -----------------------------------------------------------
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
        self.iris_r = (eye_radius + pupil_radius) // 2
        self.iris_color = iris_color
        self.pupil_color = pupil_color
        self.eye_white = eye_white
        self.bg_color = bg_color
        self.dt = 1.0 / fps

        # state
        self._look_h = self._look_v = 0.0
        self._expression = "neutral"
        self._blink_req = None           # None | both/left/right
        self._blink_t = 0.0              # running timer

        self.q: "queue.Queue[tuple[int,object]]" = queue.Queue()
        self._running = True
        threading.Thread(target=self._loop, daemon=True).start()

    # ---------------- API -----------------
    def look(self, horiz:float, vert:float=0.0):
        self.q.put((CMD_LOOK, (horiz, vert)))
    def set_expression(self, expr:str):
        self.q.put((CMD_EXPR, expr))
    def blink(self, *, eye:str="both"):
        self.q.put((CMD_BLINK, eye))
    def stop(self):
        self._running = False

    # ------------- internal loop ---------
    def _loop(self):
        w, h = self.display.width, self.display.height
        eye_y = h//3
        eye_off = w//4
        pupil_max = self.eye_r - self.pupil_r - 2
        last = time.monotonic()
        natural_blink_timer = 0.0
        while self._running:
            # consume commands
            while not self.q.empty():
                cmd, data = self.q.get()
                if cmd == CMD_LOOK:
                    self._look_h, self._look_v = data  # type: ignore
                elif cmd == CMD_EXPR:
                    self._expression = str(data)
                elif cmd == CMD_BLINK:
                    self._blink_req = str(data)
                    self._blink_t = 0.0
            now = time.monotonic()
            dt = now - last
            last = now
            natural_blink_timer += dt
            self._blink_t += dt

            # auto‑blink every 6‑9 s if nothing else
            if natural_blink_timer > random.uniform(6, 9):
                self._blink_req = "both"
                self._blink_t = 0.0
                natural_blink_timer = 0.0

            blinking = False
            blink_eye = "both"
            if self._blink_req is not None:
                if self._blink_t < 0.3:   # 300 ms blink
                    blinking = True
                    blink_eye = self._blink_req
                else:
                    self._blink_req = None

            img = Image.new("RGB", (w, h), self.bg_color)
            draw = ImageDraw.Draw(img)

            dx = int(self._look_h * pupil_max)
            dy = int(self._look_v * pupil_max)
            for idx, (cx, cy) in enumerate(((w//2 - eye_off, eye_y), (w//2 + eye_off, eye_y))):
                if blinking and (blink_eye in ("both", "left" if idx==0 else "right")):
                    draw.line((cx-self.eye_r, cy, cx+self.eye_r, cy), fill=self.eye_white, width=4)
                    continue
                # white eyeball
                draw.ellipse((cx-self.eye_r, cy-self.eye_r, cx+self.eye_r, cy+self.eye_r), fill=self.eye_white)
                # iris
                draw.ellipse((cx-self.iris_r+dx, cy-self.iris_r+dy, cx+self.iris_r+dx, cy+self.iris_r+dy), fill=self.iris_color)
                # pupil
                draw.ellipse((cx-self.pupil_r+dx, cy-self.pupil_r+dy, cx+self.pupil_r+dx, cy+self.pupil_r+dy), fill=self.pupil_color)

            # mouth
            mouth_w, mouth_h = w//2, h//4
            mx0, mx1 = w//2 - mouth_w//2, w//2 + mouth_w//2
            my = int(h*0.7)
            if self._expression == "happy":
                draw.arc((mx0, my-mouth_h//2, mx1, my+mouth_h//2), 200, 340, fill=self.eye_white, width=4)
            elif self._expression == "sad":
                draw.arc((mx0, my-mouth_h//2, mx1, my+mouth_h//2), 20, 160, fill=self.eye_white, width=4)
            else:
                draw.line((mx0, my, mx1, my), fill=self.eye_white, width=4)

            self.display.image(img)
            time.sleep(self.dt)

# singleton
face = RobotFace()

# ---------------- demo -------------------
if __name__ == "__main__":
    try:
        while True:
            choice = random.choice(["look", "expr", "blink"])
            if choice == "look":
                face.look(random.uniform(-1,1), random.uniform(-0.5,0.5))
            elif choice == "expr":
                face.set_expression(random.choice(["neutral","happy","sad"]))
            else:
                face.blink(eye=random.choice(["both","left","right"]))
            time.sleep(random.uniform(1.0, 2.5))
    except KeyboardInterrupt:
        face.stop()
