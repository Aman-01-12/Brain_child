# KioMeet Mini Project — Presenter Script

Quick-reference spoken script for the mid-sem evaluation. Each section is
written to be spoken in under a minute — read it a couple of times and say
it in your own words rather than memorizing it word for word.

## Amrit Kashyap — Testing & Quality Assurance

I worked on testing two of the main features in our project, KioMeet.
First, I tested Secure Interview Mode — that's the feature that locks an
interview session to one shared window. I tried to share a second window
while a session was locked, and confirmed the app blocked it every time, so
nothing extra ever leaked to the candidate.
Second, I tested the live chat, polls, and Q&A. I opened the app on two
accounts at the same time and checked that a chat message, a poll, and a
question all showed up instantly on the other screen, without needing to
refresh.
Whenever I found something that didn't work the way it should, I logged it
and reported it back to the team so it could be fixed before the demo.

### If the professor asks...

- **"How did you test it?"**
  I used two accounts running at the same time — one as the host and one
  as a participant — and checked what each side actually saw, instead of
  just reading the code.
- **"What would happen if two people tried to share a window at once?"**
  Once a session is locked to one window, the app rejects any attempt to
  attach a second one — I confirmed this by trying it myself during
  testing.
- **"Did you find any bugs?"**
  Yes, a few small issues came up during testing — I logged each one and
  the team fixed them before the final demo.
- **"Why does this feature matter?"**
  Because in a real interview, you don't want the candidate accidentally
  seeing private windows on the interviewer's screen — this feature makes
  sure only the intended window is ever visible.
- **If asked how the lock is actually implemented in code:** That part of
  the implementation was built by Aman — I can speak to how we verified it
  works.

## Ankit Kashyap — Documentation & Demo Coordination

I worked on documentation and getting things ready for the demo. I
documented how meeting scheduling and team management work in our project,
for the project report, so anyone reading it can understand those features
without digging into the code.
Before each presentation, I prepared the demo environment — setting up
test accounts and starting the server ahead of time, so the live demo runs
smoothly without delays.
I also went through the app's screens and gave feedback on anything that
felt unclear, so the interface stays easy to follow.

### If the professor asks...

- **"What do you mean by preparing the demo?"**
  I set up test accounts in advance and started the server before the
  presentation, so we're not wasting time setting things up live in front
  of the panel.
- **"What does the scheduling feature do?"**
  It lets a host create a meeting in advance and send out the meeting
  details, so participants know when and where to join.
- **"Why did you need test accounts ready beforehand?"**
  Creating accounts live during the demo takes time and can go wrong — having
  them ready in advance keeps the demo short and reliable.
- **"What did you document?"**
  I documented how scheduling meetings and managing teams work, in plain
  language, for the project report.
- **If asked how scheduling or team management is implemented in code:**
  That part of the implementation was built by Aman — I can speak to how it
  works for the user and how we prepared it for the demo.
