"""Extract a hand grip from a photograph (or a webcam) for the XR suite.

Point it at a picture of someone holding the object you care about - a spray
can, a pistol grip, a drill - and it writes the 21 MediaPipe world landmarks
as JSON. XRGripImport turns that into a grip resource the suite plays back,
so a reference image becomes a hold without anyone recording or hand-authoring
anything.

Why an image is worth having at all: an analytic fit curls each finger around
one hinge until it touches the collider, which closes plausibly and never
humanly - no splay, no thumb rolling across the barrel, no per-joint
variation. A photograph has all three, because a person did it.

What an image cannot give: reliable absolute depth. MediaPipe's world
landmarks are metric-ish and wrist-relative, good for SHAPE and approximate in
scale, which is exactly why the suite snaps an imported grip onto the object's
collider afterwards. Photo supplies the structure, geometry supplies the
dimensions.

Usage
-----
  python grip_from_image.py --image spray_grip.jpg --name grip_spray_can
  python grip_from_image.py --webcam --name grip_blaster
  python grip_from_image.py --image gun.jpg --name grip_blaster --hand left

Output: <name>.json next to the script, or --out <path>.
Import in Godot:
  XRGripImport.import_json("<path>", "<name>", "res://grips")
"""

import argparse
import json
import sys
from pathlib import Path

import cv2
import mediapipe as mp
from mediapipe.tasks.python import BaseOptions
from mediapipe.tasks.python.vision import (HandLandmarker, HandLandmarkerOptions,
                                           RunningMode)

# MediaPipe 1.x replaced the old `mp.solutions.hands` module with the Tasks
# API, which loads an explicit model file instead of bundling one. The model
# is a download, so it stays out of the repo like the library itself - point
# GRIP_LANDMARKER_MODEL at it, or drop hand_landmarker.task beside this script.
DEFAULT_MODEL = "hand_landmarker.task"


def landmarks_from_image(path, want_hand):
    image = cv2.imread(str(path))
    if image is None:
        sys.exit(f"could not read image: {path}")
    return _detect(image, want_hand, still=True)


def landmarks_from_webcam(want_hand, camera=0):
    """Hold the real object in front of the camera and press SPACE.

    Better than a found photograph when you own the object: the grip is yours,
    the hand is the one that will be playing it back, and you can re-take it
    until it looks right. Press Q to give up.
    """
    capture = cv2.VideoCapture(camera)
    if not capture.isOpened():
        sys.exit("no camera")
    print("hold the object, SPACE to capture, Q to quit")
    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                continue
            preview = frame.copy()
            found = _detect(frame, want_hand, still=False)
            cv2.putText(preview, "hand detected" if found else "no hand",
                        (12, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.9,
                        (0, 220, 0) if found else (0, 0, 220), 2)
            cv2.imshow("grip capture", preview)
            key = cv2.waitKey(1) & 0xFF
            if key == ord(" ") and found:
                return found
            if key == ord("q"):
                sys.exit("cancelled")
    finally:
        capture.release()
        cv2.destroyAllWindows()


def _model_path():
    import os
    override = os.environ.get("GRIP_LANDMARKER_MODEL")
    if override and Path(override).exists():
        return override
    for candidate in (Path(__file__).with_name(DEFAULT_MODEL),
                      Path.cwd() / DEFAULT_MODEL,
                      Path("C:/ws/xr/testbed") / DEFAULT_MODEL):
        if candidate.exists():
            return str(candidate)
    sys.exit(
        "hand_landmarker.task not found. Download it once: "
        "  curl -L -o hand_landmarker.task https://storage.googleapis.com/"
        "mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task")


def _detect(image, want_hand, still):
    """World landmarks for the requested hand, or None.

    WORLD landmarks, not the normalized image ones: they are wrist-origin and
    roughly metric, so they describe a hand in space rather than a hand on a
    picture. The suite retargets onto the playing hand's own bone lengths, so
    approximate scale is fine - proportions are what matter.
    """
    options = HandLandmarkerOptions(
        base_options=BaseOptions(model_asset_path=_model_path()),
        running_mode=RunningMode.IMAGE,
        num_hands=2,
        min_hand_detection_confidence=0.4,
    )
    with HandLandmarker.create_from_options(options) as landmarker:
        frame = mp.Image(image_format=mp.ImageFormat.SRGB,
                         data=cv2.cvtColor(image, cv2.COLOR_BGR2RGB))
        result = landmarker.detect(frame)
        if not result.hand_world_landmarks:
            return None
        index = 0
        # MediaPipe labels the hand as seen in the image; an un-mirrored photo
        # of a right hand reads "Right". Pick the one asked for when both are
        # visible, rather than whichever was detected first.
        if result.handedness and want_hand:
            for i, handed in enumerate(result.handedness):
                if handed[0].category_name.lower() == want_hand:
                    index = i
                    break
        return [[p.x, p.y, p.z] for p in result.hand_world_landmarks[index]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--image", type=Path, help="reference photo of the grip")
    source.add_argument("--webcam", action="store_true", help="capture from a camera")
    parser.add_argument("--name", required=True,
                        help="grip name; use grip_<object scene name> so a grab point finds it")
    parser.add_argument("--hand", choices=["left", "right"], default="right")
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    marks = (landmarks_from_webcam(args.hand, args.camera) if args.webcam
             else landmarks_from_image(args.image, args.hand))
    if not marks:
        sys.exit("no hand found - try a clearer view of the whole hand")

    out = args.out or Path(__file__).with_name(f"{args.name}.json")
    out.write_text(json.dumps({
        "landmarks": marks,
        "hand": args.hand,
        "source": "webcam" if args.webcam else str(args.image),
    }, indent=1))
    print(f"wrote {out} ({len(marks)} landmarks)")
    print(f'import: XRGripImport.import_json("{out.as_posix()}", "{args.name}", "res://grips")')


if __name__ == "__main__":
    main()
