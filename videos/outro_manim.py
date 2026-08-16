from manim import *
import os
import random
import numpy as np

FONT_PATH = os.path.join(os.path.dirname(__file__), "fonts", "EBGaramond.ttf")
MUSIC_PATH = os.path.join(os.path.dirname(__file__), "music", "lily.wav")
MUSIC_DURATION = 14.285708

FONT_SIZE = 40

# One uniform colour for all text, picked from the Evangelion credits palette.
# Other picked swatches: #EF7E16 #D95710 #FCD623 #E42F00 #AF3505
TEXT_COLOR = "#FBAB24"

# Credit lines are picked at random (seeded, so the still and the full render
# match). "" would be a blank spacer; blanks are inserted by BLANK_PROB.
CHOICES = ["navylilyworks", "tiagohierath", "navylily.tv"]
SEED = 7

# --- Helix / perspective geometry (every point is hand-projected; manim's own
#     3D perspective is too weak for this Evangelion-credits look) ---
R = 4.0            # radius of the vertical curve that bends away top & bottom
CAM = 8.5          # camera distance along +Z
FOC = CAM - R      # focal length -> a line at screen centre renders at scale 1.0
ARC = 0.37         # arc-length gap between consecutive lines (world units)
THETA_HIDE = 1.45  # hide lines past this angle (near-edge-on, off toward a point)
HELIX_AMP = 0.15   # subtle side-to-side snake on top of the path
HELIX_W = 1.0      # winding rate of that snake
# Horizontal path (world units, screen centre = 0), fit through three heights:
# enters bottom-right, swings to mid-left (left third), exits top-right.
X_BOTTOM = 2.6
X_MID = -0.9
X_TOP = 1.0
_PA = (X_TOP + X_BOTTOM) / 2 - X_MID
_PB = (X_TOP - X_BOTTOM) / 2
_PC = X_MID
TURN = 1.15        # head-turn: vertical-axis rotation per unit angle
ALPHA_CLAMP = 1.48 # cap the turn just shy of fully edge-on (~85 deg)
SPEED = 0.80       # arc-units per second the helix scrolls upward (20% slower)
ZOOM = 2.0         # zoom in so the near-edge-on start/end tips are cropped off
                   #   (tuned for the 4:3 frame)
VSTRETCH = 1.15    # push the entry (bottom) and exit (top) points further apart

MAIN_SPAN = 6.8    # arc-length of the main random stream (~ how many lines)
LONE_GAP = 2.0     # empty beat after the stream, before the lone final line
LONE_TEXT = "navylily.tv"   # the final line that passes alone (no music)


def make_line(text):
    if not text:
        return VGroup()   # blank spacer line
    txt = Text(text, font="EB Garamond", font_size=FONT_SIZE)
    txt.set_color(TEXT_COLOR)
    txt.center()
    return txt


def project_line(mob, fam, pris, base, scroll_value):
    u = scroll_value - base                 # arc position; +up
    th = u / R
    if abs(th) > THETA_HIDE:
        mob.set_opacity(0.0)
        return
    Yc = R * np.sin(th)                      # curve that bends away top & bottom
    Zc = R * np.cos(th)
    t = th / THETA_HIDE
    Xc = _PA * t * t + _PB * t + _PC + HELIX_AMP * np.sin(HELIX_W * th)
    al = float(np.clip(TURN * th, -ALPHA_CLAMP, ALPHA_CLAMP))
    ca, sa = np.cos(al), np.sin(al)
    fade = np.clip(np.cos(th), 0.0, 1.0) ** 1.3
    for m, P in zip(fam, pris):
        px, py = P[:, 0], P[:, 1]
        Wx = Xc + px * ca                    # rotate about own vertical axis
        Wz = Zc - px * sa
        Wy = VSTRETCH * Yc + py              # spread line centres, keep glyph size
        depth = CAM - Wz
        sx = ZOOM * FOC * Wx / depth
        sy = ZOOM * FOC * Wy / depth
        m.set_points(np.column_stack([sx, sy, np.zeros_like(sx)]))
    mob.set_opacity(0.04 + 0.96 * fade)


def build(scene):
    b_min = R * THETA_HIDE + 0.8
    b_main_max = b_min + MAIN_SPAN
    main_bases = list(np.arange(b_min, b_main_max + ARC, ARC))
    # The lone final line sits a full screen-height past the stream (plus a beat)
    # so it enters only after every stream line has left: it passes alone.
    b_lone = b_main_max + 2 * R * THETA_HIDE + LONE_GAP
    bases = main_bases + [b_lone]
    scroll_end = b_lone + R * THETA_HIDE + 0.8

    group = VGroup()
    fams, prisms = [], []
    rng = random.Random(SEED)
    for i, base in enumerate(bases):
        text = LONE_TEXT if i == len(bases) - 1 else rng.choice(CHOICES)
        ln = make_line(text)
        fam = ln.family_members_with_points()
        fams.append(fam)
        prisms.append([m.get_points().copy() for m in fam])
        group.add(ln)
    scene.add(group)
    return group, fams, prisms, bases, scroll_end


class Outro(Scene):
    def construct(self):
        self.camera.background_color = BLACK
        self.add_sound(MUSIC_PATH)
        self.add_sound(MUSIC_PATH, time_offset=MUSIC_DURATION)

        with register_font(FONT_PATH):
            scroll = ValueTracker(0.0)
            group, fams, prisms, bases, scroll_end = build(self)

            def make_updater(fam, pris, base):
                return lambda m: project_line(m, fam, pris, base, scroll.get_value())

            for ln, fam, pris, base in zip(group, fams, prisms, bases):
                upd = make_updater(fam, pris, base)
                upd(ln)
                ln.add_updater(upd)

            self.play(
                scroll.animate.set_value(scroll_end),
                run_time=scroll_end / SPEED,
                rate_func=linear,
            )


class OutroStill(Scene):
    """Single mid-roll frame for fast previews: manim -s ... OutroStill"""

    def construct(self):
        self.camera.background_color = BLACK
        with register_font(FONT_PATH):
            group, fams, prisms, bases, scroll_end = build(self)
            mid = scroll_end * 0.5
            for ln, fam, pris, base in zip(group, fams, prisms, bases):
                project_line(ln, fam, pris, base, mid)
