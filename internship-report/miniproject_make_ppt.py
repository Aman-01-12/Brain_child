#!/usr/bin/env python3
"""Generate the mini-project presentation deck (9 slides) as an editable .pptx.

Mid-semester evaluation deck for a 3-person B.Tech CSE mini project
(KioMeet — a secure video conferencing & technical interview platform).
This is a parallel deck to internship_presentation.pptx (which stays
untouched) — same visual machinery (palette, header/footer, bullets,
rounded screenshot cards, architecture stack diagram), new content.

Screenshots are KioMeet UI reference screens from inter-design-handoff/.
Each screenshot is pre-processed into a rounded card with a soft drop shadow
(corners of the image itself are rounded — no square-image-on-rounded-mat
mismatch). Run:  .venv/bin/python internship-report/miniproject_make_ppt.py
"""
import os
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "miniproject_presentation.pptx")
LOGO = os.path.join(HERE, "logo.png")
REF = os.path.join(HERE, "..", "inter-design-handoff", "reference-screens")
CACHE = os.path.join(HERE, ".ppt_assets")
os.makedirs(CACHE, exist_ok=True)

# ---- Palette --------------------------------------------------------------
NAVY   = RGBColor(0x1F, 0x2A, 0x44)
NAVY2  = RGBColor(0x2B, 0x3A, 0x5E)
TEAL   = RGBColor(0x17, 0xA3, 0x98)
DARK   = RGBColor(0x1E, 0x24, 0x2E)
MUTED  = RGBColor(0x55, 0x60, 0x6B)
LIGHT  = RGBColor(0xEE, 0xF1, 0xF6)
WHITE  = RGBColor(0xFF, 0xFF, 0xFF)
FONT   = "Arial"

prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
SW, SH = prs.slide_width, prs.slide_height
BLANK = prs.slide_layouts[6]
FOOTER = "23BCS012   ·   23BCS014   ·   23BCS017   ·   KioMeet Mini Project"


# ---- image helper: rounded corners + soft shadow --------------------------
def rounded_card(src_name):
    src = os.path.join(REF, src_name + ".png")
    dst = os.path.join(CACHE, src_name + "_card.png")
    if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
        return dst
    im = Image.open(src).convert("RGBA")
    w, h = im.size
    r = int(min(w, h) * 0.035)
    # round the image corners
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], r, fill=255)
    im.putalpha(mask)
    # subtle inner border for crispness on white
    bd = max(2, int(min(w, h) * 0.0025))
    ImageDraw.Draw(im).rounded_rectangle(
        [bd // 2, bd // 2, w - 1 - bd // 2, h - 1 - bd // 2],
        r, outline=(74, 86, 112, 255), width=bd)
    # soft drop shadow on a transparent canvas
    m = int(min(w, h) * 0.06)
    canvas = Image.new("RGBA", (w + 2 * m, h + 2 * m), (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [m, m + int(m * 0.35), m + w, m + int(m * 0.35) + h],
        r, fill=(12, 18, 30, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(m * 0.5))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(im, (m, m))
    canvas.save(dst)
    return dst


def _run(p, text, size, bold=False, color=DARK, italic=False, font=FONT):
    r = p.add_run()
    r.text = text
    r.font.size = Pt(size)
    r.font.bold = bold
    r.font.italic = italic
    r.font.name = font
    r.font.color.rgb = color
    return r


def rect(slide, left, top, width, height, fill, line=None, rounded=False):
    shp = slide.shapes.add_shape(
        MSO_SHAPE.ROUNDED_RECTANGLE if rounded else MSO_SHAPE.RECTANGLE,
        left, top, width, height)
    shp.fill.solid()
    shp.fill.fore_color.rgb = fill
    if line is None:
        shp.line.fill.background()
    else:
        shp.line.color.rgb = line
        shp.line.width = Pt(1)
    shp.shadow.inherit = False
    return shp


def textbox(slide, left, top, width, height, anchor=MSO_ANCHOR.TOP):
    tb = slide.shapes.add_textbox(left, top, width, height)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_left = 0
    tf.margin_right = 0
    tf.margin_top = 0
    tf.margin_bottom = 0
    return tf


MARGIN = Inches(0.7)


def header(slide, title):
    rect(slide, 0, 0, SW, Inches(1.25), NAVY)
    rect(slide, 0, Inches(1.25), SW, Inches(0.07), TEAL)
    tf = textbox(slide, MARGIN, 0, Inches(12.0), Inches(1.25),
                 anchor=MSO_ANCHOR.MIDDLE)
    _run(tf.paragraphs[0], title, 30, bold=True, color=WHITE)


def footer(slide, n):
    tf = textbox(slide, MARGIN, Inches(7.02), Inches(9.5), Inches(0.35),
                 anchor=MSO_ANCHOR.MIDDLE)
    _run(tf.paragraphs[0], FOOTER, 10, color=MUTED)
    tf2 = textbox(slide, Inches(12.0), Inches(7.02), Inches(0.9), Inches(0.35),
                  anchor=MSO_ANCHOR.MIDDLE)
    p = tf2.paragraphs[0]
    p.alignment = PP_ALIGN.RIGHT
    _run(p, str(n), 11, bold=True, color=TEAL)


def bullets(slide, items, left=MARGIN, top=Inches(1.65),
            width=Inches(11.9), height=Inches(5.0), size=20,
            anchor=MSO_ANCHOR.TOP):
    tf = textbox(slide, left, top, width, height, anchor=anchor)
    first = True
    for text, level in items:
        p = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        p.alignment = PP_ALIGN.LEFT
        if level == 0:
            p.space_before = Pt(13)
            p.space_after = Pt(2)
            _run(p, "\u25AA  ", size, bold=True, color=TEAL)
            _run(p, text, size, color=DARK)
        else:
            p.space_before = Pt(5)
            p.space_after = Pt(2)
            _run(p, "      \u2013  ", size - 2, color=MUTED)
            _run(p, text, size - 2, color=MUTED)
        p.line_spacing = 1.1
    return tf


def place_image(slide, src_name, bl, bt, bw, bh, caption=None):
    path = rounded_card(src_name)
    with Image.open(path) as im:
        iw, ih = im.size
    ar = iw / ih
    box_ar = bw / bh
    if ar >= box_ar:
        w = int(bw); h = int(bw / ar)
    else:
        h = int(bh); w = int(bh * ar)
    left = int(bl + (bw - w) / 2)
    top = int(bt + (bh - h) / 2)
    slide.shapes.add_picture(path, left, top, width=w, height=h)
    if caption:
        cf = textbox(slide, bl, int(bt + bh + Inches(0.05)), bw, Inches(0.6))
        cp = cf.paragraphs[0]
        cp.alignment = PP_ALIGN.CENTER
        _run(cp, caption, 13, italic=True, color=MUTED)


def stack_box(slide, left, top, width, height, title, sub, fill, focus=False):
    shp = rect(slide, left, top, width, height, fill, rounded=True,
               line=(TEAL if focus else None))
    if focus:
        shp.line.width = Pt(2.75)
    tf = shp.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    tf.margin_left = Inches(0.15)
    tf.margin_right = Inches(0.15)
    p = tf.paragraphs[0]
    p.alignment = PP_ALIGN.CENTER
    _run(p, title, 16, bold=True, color=WHITE)
    p2 = tf.add_paragraph()
    p2.alignment = PP_ALIGN.CENTER
    _run(p2, sub, 12, color=LIGHT)


def down_arrow(slide, cx, top, h=Inches(0.26)):
    w = Inches(0.3)
    a = slide.shapes.add_shape(MSO_SHAPE.DOWN_ARROW, int(cx - w / 2), top, w, h)
    a.fill.solid()
    a.fill.fore_color.rgb = TEAL
    a.line.fill.background()
    a.shadow.inherit = False


# ---- NEW helper (slide 5 only): a readable "who did what" card ------------
# Built from the same rect()/textbox()/_run() primitives above, in the same
# palette, so it matches the rest of the deck without touching make_ppt.py.
def contribution_card(slide, left, top, width, height, name, role, points):
    rect(slide, left, top, width, height, LIGHT, rounded=True)
    rect(slide, left, top, Inches(0.09), height, TEAL)
    tf = textbox(slide, int(left + Inches(0.35)), int(top + Inches(0.14)),
                 int(width - Inches(0.6)), int(height - Inches(0.26)))
    p = tf.paragraphs[0]
    _run(p, name, 18, bold=True, color=NAVY)
    _run(p, "   —   " + role, 14, bold=True, color=TEAL)
    for pt in points:
        pp = tf.add_paragraph()
        pp.space_before = Pt(5)
        _run(pp, "\u2013  ", 13, color=MUTED)
        _run(pp, pt, 13, color=DARK)
        pp.line_spacing = 1.05


# split-slide geometry (text left / screenshot right)
TL, TT, TWD, THT = MARGIN, Inches(1.7), Inches(5.7), Inches(5.0)
IL, IT, IWD, IHT = Inches(6.75), Inches(1.6), Inches(6.1), Inches(4.75)

TEAM = [
    ("Aman Verma", "23BCS012"),
    ("Amrit Kashyap", "23BCS014"),
    ("Ankit Kashyap", "23BCS017"),
]

# =====================================================================
# SLIDE 1 — TITLE
# =====================================================================
s = prs.slides.add_slide(BLANK)
rect(s, 0, 0, SW, SH, NAVY)
rect(s, 0, 0, Inches(0.3), SH, TEAL)
rect(s, Inches(0.95), Inches(2.15), Inches(2.3), Inches(0.09), TEAL)

tf = textbox(s, Inches(0.95), Inches(1.4), Inches(11.0), Inches(0.6))
_run(tf.paragraphs[0], "MINI PROJECT", 18, bold=True, color=TEAL)

tf = textbox(s, Inches(0.95), Inches(2.45), Inches(11.3), Inches(1.7))
_run(tf.paragraphs[0], "KioMeet", 44, bold=True, color=WHITE)
p = tf.add_paragraph()
p.space_before = Pt(8)
_run(p, "A Secure Video Conferencing & Technical Interview Platform",
     22, color=LIGHT)

tf = textbox(s, Inches(0.95), Inches(4.35), Inches(11.0), Inches(1.75))
first = True
for i, (name, entry) in enumerate(TEAM):
    p = tf.paragraphs[0] if first else tf.add_paragraph()
    first = False
    if i > 0:
        p.space_before = Pt(8)
    _run(p, name, 20, bold=True, color=WHITE)
    _run(p, "   —   " + entry, 15, color=LIGHT)

tf = textbox(s, Inches(0.95), Inches(6.25), Inches(11.3), Inches(1.0))
_run(tf.paragraphs[0],
     "Mini Project   ·   B.Tech CSE   ·   Mid-Semester Evaluation",
     14, color=TEAL, bold=True)
p = tf.add_paragraph()
p.space_before = Pt(4)
_run(p, "B.Tech, Computer Science & Engineering   —   Shri Mata Vaishno Devi "
        "University, Katra", 13, color=LIGHT)

if os.path.exists(LOGO):
    s.shapes.add_picture(LOGO, Inches(11.3), Inches(0.6), height=Inches(1.3))

# =====================================================================
# SLIDE 2 — PROJECT AT A GLANCE
# =====================================================================
s = prs.slides.add_slide(BLANK)
header(s, "Project at a Glance")
bullets(s, [
    ("Mini Project — B.Tech CSE, mid-semester evaluation, team of 3.", 0),
    ("Team: Aman Verma, Amrit Kashyap, Ankit Kashyap.", 0),
    ("KioMeet in one line: a secure video-conferencing and "
     "technical-interview platform.", 0),
    ("Project phases: Requirement Analysis \u2192 Design \u2192 "
     "Implementation \u2192 Testing \u2192 Demo.", 0),
], size=22, top=Inches(1.75), height=Inches(5.0))
footer(s, 2)

# =====================================================================
# SLIDE 3 — PROJECT & PROBLEM  (+ secure interview mode screenshot)
# =====================================================================
s = prs.slides.add_slide(BLANK)
header(s, "KioMeet — The Project & the Problem")
bullets(s, [
    ("A desktop video-calling app for team meetings and technical "
     "interviews (Windows & Mac).", 0),
    ("Problem: in a normal screen-share, private windows on the "
     "interviewer's screen can accidentally leak to the candidate.", 0),
    ("Goal: make sure the candidate only ever sees the one window the "
     "interviewer chooses to share — nothing else.", 0),
    ("Also in scope: reliable calls, recording, scheduling, and "
     "subscription-based features.", 0),
], left=TL, top=TT, width=TWD, height=THT, size=19,
   anchor=MSO_ANCHOR.MIDDLE)
place_image(s, "ref_secure_dark", IL, IT, IWD, IHT,
            caption="Secure interview mode — the candidate sees only the "
                    "shared code editor, nothing else.")
footer(s, 3)

# =====================================================================
# SLIDE 4 — SYSTEM ARCHITECTURE (bullets + stacked diagram)
# =====================================================================
s = prs.slides.add_slide(BLANK)
header(s, "How the System Fits Together")
bullets(s, [
    ("The app has four building blocks:", 0),
    ("The app itself — handles camera, mic, and screen on your "
     "computer.", 1),
    ("The video engine — carries live audio/video between participants.", 1),
    ("The server (our area) — logins, meeting links, recordings, "
     "subscriptions.", 1),
    ("The databases — store accounts permanently; store live meeting "
     "info temporarily.", 1),
    ("Our project focuses on the server.", 0),
], left=TL, top=Inches(1.7), width=Inches(6.2), height=Inches(5.0), size=17,
   anchor=MSO_ANCHOR.MIDDLE)

dx, dw = Inches(7.4), Inches(5.2)
top0 = Inches(1.75)
bh, gap = Inches(1.02), Inches(0.42)
boxes = [
    ("Desktop App", "What the user sees and uses", NAVY, False),
    ("Video Engine", "Carries the live call", NAVY2, False),
    ("Server", "Our focus — secure sessions, live updates, meetings", TEAL, True),
    ("Databases", "Account data + live meeting data", NAVY2, False),
]
y = top0
for i, (t, sub, fill, focus) in enumerate(boxes):
    stack_box(s, dx, y, dw, bh, t, sub, fill, focus=focus)
    if i < len(boxes) - 1:
        down_arrow(s, dx + dw / 2, int(y + bh + Inches(0.08)))
    y = int(y + bh + gap)
footer(s, 4)

# =====================================================================
# SLIDE 5 — TEAM CONTRIBUTIONS  (new slide: 3 stacked cards)
# =====================================================================
s = prs.slides.add_slide(BLANK)
header(s, "Team Contributions")

card_left = MARGIN
card_width = SW - 2 * MARGIN
card_h = Inches(1.75)
card_gap = Inches(0.13)
card_top = Inches(1.45)

contribution_card(
    s, card_left, card_top, card_width, card_h,
    "Aman Verma", "Core Development",
    [
        "Secure Interview Mode — backend logic that locks a session to "
        "one shared window.",
        "Live Chat, Polls & Q&A — the real-time updates participants "
        "see during a call.",
        "Login & scheduling groundwork.",
    ])

card_top = int(card_top + card_h + card_gap)
contribution_card(
    s, card_left, card_top, card_width, card_h,
    "Amrit Kashyap", "Testing & Quality Assurance",
    [
        "Tested that Secure Interview Mode actually blocks a second "
        "shared window once a session is locked.",
        "Tested that chat messages, poll votes, and Q&A questions reach "
        "every participant instantly, with no refresh needed.",
        "Logged and reported issues found during testing.",
    ])

card_top = int(card_top + card_h + card_gap)
contribution_card(
    s, card_left, card_top, card_width, card_h,
    "Ankit Kashyap", "Documentation & Demo Coordination",
    [
        "Documented how meeting scheduling and team management work, "
        "for the project report.",
        "Prepared the demo environment — test accounts, starting the "
        "server — before presentations.",
        "Reviewed the app's screens for clarity.",
    ])
footer(s, 5)

# =====================================================================
# SLIDE 6 — HIGHLIGHT 1: SECURE INTERVIEW MODE
#            (+ host & candidate screenshots side by side)
# =====================================================================
s = prs.slides.add_slide(BLANK)
header(s, "Highlight 1 — Secure Interview Mode")
bullets(s, [
    ("The problem: during a normal screen-share, a candidate could "
     "accidentally see private windows on the interviewer's screen.", 0),
    ("What was built: the backend creates a locked interview session "
     "that allows exactly one shared window — nothing else can be "
     "attached to it.", 0),
    ("If anyone tries to share a second window, the backend rejects "
     "it, so the lock can't be bypassed from either side.", 0),
    ("Result: the candidate only ever sees the one code editor the "
     "interviewer picked.", 0),
], left=MARGIN, top=Inches(1.65), width=Inches(5.5), height=Inches(5.0),
   size=17, anchor=MSO_ANCHOR.MIDDLE)

# two stacked screenshots: host view (top) and candidate view (bottom)
col_l, col_w = Inches(6.5), Inches(6.3)
half_h = Inches(2.35)
place_image(s, "ref_secure_dark", col_l, Inches(1.5), col_w, half_h,
            caption="Interviewer's view")
place_image(s, "ref_secure-candidate_dark", col_l, Inches(4.35), col_w,
            half_h, caption="Candidate's view — same shared window, "
                            "nothing more")
footer(s, 6)

# =====================================================================
# SLIDE 7 — HIGHLIGHT 2: LIVE CHAT, POLLS & Q&A  (+ poll screenshot)
# =====================================================================
s = prs.slides.add_slide(BLANK)
header(s, "Highlight 2 — Live Chat, Polls & Q&A")
bullets(s, [
    ("During a call, the host can launch a poll or open the Q&A board "
     "at any time.", 0),
    ("A real-time connection instantly pushes these updates to every "
     "participant — no refreshing, no delay.", 0),
    ("A chat message, a new poll, or a vote all travel the same way: "
     "sent once, delivered to everyone in that meeting immediately.", 0),
    ("This keeps everyone in a meeting looking at the same screen at "
     "the same time.", 0),
], left=TL, top=TT, width=TWD, height=THT, size=18, anchor=MSO_ANCHOR.MIDDLE)
place_image(s, "ref_poll_dark", IL, IT, IWD, IHT,
            caption="Launching a live poll — results update instantly "
                    "for every participant.")
footer(s, 7)

# =====================================================================
# SLIDE 8 — TESTING & RESULTS  (+ in-call screenshot)
# =====================================================================
s = prs.slides.add_slide(BLANK)
header(s, "Testing & Results")
bullets(s, [
    ("Testing led by Amrit Kashyap:", 0),
    ("Secure Interview Mode: tested that a second shared window is "
     "always rejected once a session is locked — no exceptions.", 0),
    ("Live Chat/Polls/Q&A: tested that every participant in a room "
     "receives updates at the same time, with nothing missed.", 0),
    ("End-to-end flow tested: register \u2192 log in \u2192 create a "
     "meeting \u2192 join it.", 0),
    ("All test results were reviewed by the team ahead of the final "
     "demo.", 0),
], left=TL, top=TT, width=TWD, height=THT, size=18, anchor=MSO_ANCHOR.MIDDLE)
place_image(s, "ref_in-call_dark", IL, IT, IWD, IHT,
            caption="A live call — the end-to-end flow this testing "
                    "covers.")
footer(s, 8)

# =====================================================================
# SLIDE 9 — CONCLUSION & FUTURE SCOPE
# =====================================================================
s = prs.slides.add_slide(BLANK)
header(s, "Conclusion & Future Scope")
bullets(s, [
    ("This mini project gave our team hands-on experience across "
     "development, testing, and documentation — building, verifying, "
     "and presenting a complete feature end-to-end.", 0),
    ("What's next for the project:", 0),
    ("support more cloud storage options for recordings;", 1),
    ("tighten data access rules for extra security;", 1),
    ("add more automated tests that mimic real user behaviour.", 1),
], size=20, top=Inches(1.75), height=Inches(3.9))
rect(s, MARGIN, Inches(5.85), Inches(11.93), Inches(1.0), LIGHT, rounded=True)
tf = textbox(s, Inches(0.95), Inches(5.85), Inches(11.4), Inches(1.0),
             anchor=MSO_ANCHOR.MIDDLE)
p = tf.paragraphs[0]
_run(p, "Thank you.  ", 22, bold=True, color=NAVY)
_run(p, "Questions & discussion welcome.", 20, color=TEAL, bold=True)
footer(s, 9)

prs.save(OUT)
print("Saved:", OUT, "| slides:", len(prs.slides._sldIdLst))
