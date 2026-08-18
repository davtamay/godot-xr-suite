# Grip extraction tools

`grip_from_image.py` turns a photograph (or a webcam view) of a hand holding
something into the landmark JSON `XRGripImport` reads.

**Nothing here ships, and nothing here is vendored.** The addon itself is four
small GDScript/config files; this directory holds one ~5 KB script. MediaPipe
is a few hundred megabytes of wheels and stays on the machine of whoever is
authoring grips — it is a developer tool in the same class as the shader
baker, not a runtime dependency. A game that plays imported grips needs none
of it: by then a grip is a `.tres` like any other resource.

Install on an authoring machine only:

    python -m pip install mediapipe opencv-python numpy

Then:

    python grip_from_image.py --image spray_grip.jpg --name grip_spray_can
    python grip_from_image.py --webcam --name grip_blaster

Name grips `grip_<object scene name>` — that is what a grab point looks up, so
`spray_can.tscn` wants `grip_spray_can`. Move the finished `.tres` into
`res://grips` so it ships with the project; `user://` is authoring-only and on
web is per-browser storage a player never sees.
