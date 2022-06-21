import os
import sys
import shutil
import subprocess
import multiprocessing

MAKE_PARALLEL_ARGS = ["-j" + str(multiprocessing.cpu_count())]

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

def run(*args, **kwargs):
    if not 'check' in kwargs:
        kwargs['check'] = True
    eprint("[RUN] " + subprocess.list2cmdline(*args))
    sys.stdout.flush()
    return subprocess.run(*args, **kwargs)

def download(url, filename):
    makedirs(os.path.dirname(filename))
    tmp_filename = filename + ".downloading"
    if os.path.exists(tmp_filename):
        os.remove(tmp_filename)
    if shutil.which("wget"):
        run(["wget", url, "--output-document", tmp_filename])
    run(["curl", url, "--output", tmp_filename])
    os.rename(tmp_filename, filename)

def makedirs(path):
    if not os.path.exists(path):
        os.makedirs(path)

def rmtree(path):
    if os.path.exists(path):
        shutil.rmtree(path)

def readFile(file_path):
    with open(file_path, "r") as f:
        return f.read()

def appendFile(file_path, content):
    with open(file_path, "a") as f:
        f.write(content)

