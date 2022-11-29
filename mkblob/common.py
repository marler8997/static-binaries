import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VERSION = "ad7a8da141d08b47404bc47c3e5791cc7db07ff6"
NAME_VERSION = "mkblob-" + VERSION
SRC_PATH = os.path.join(SCRIPT_DIR, NAME_VERSION)
MKBLOB = os.path.join(SRC_PATH, "mkblob")
