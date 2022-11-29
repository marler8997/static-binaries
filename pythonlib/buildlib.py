import os
import sys
import shutil
import subprocess
import multiprocessing

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
MAKE_PARALLEL_ARGS = ["-j" + str(multiprocessing.cpu_count())]
DOWNLOADS_DIR = os.path.join(REPO_ROOT, "downloads")

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

def run(*args, **kwargs):
    if not 'check' in kwargs:
        kwargs['check'] = True
    eprint("[RUN] " + subprocess.list2cmdline(*args))
    sys.stdout.flush()
    return subprocess.run(*args, **kwargs)

def download(url, file_basename):
    path = os.path.join(DOWNLOADS_DIR, file_basename)
    if os.path.exists(path):
        eprint("{} already downloaded".format(file_basename))
    else:
        makedirs(DOWNLOADS_DIR)
        #
        # TODO: use lock file if we want to support parallel jobs
        #
        tmp_path = path + ".downloading"
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        eprint("downloading {}...".format(file_basename))
        if shutil.which("wget"):
            run(["wget", url, "--output-document", tmp_path])
        else:
            run(["curl", url, "--output", tmp_path])
        os.rename(tmp_path, path)
    return path

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

class AttrDict(dict):
    def __init__(self, *args, **kwargs):
        super(AttrDict, self).__init__(*args, **kwargs)
        self.__dict__ = self

def loadPkgFile(filename):
    file_globals = {"__file__": filename}
    file_locals = AttrDict()
    with open(filename, "r") as f:
        code = compile(f.read(), filename, "exec")
        exec(code, file_globals, file_locals)
    return file_locals
