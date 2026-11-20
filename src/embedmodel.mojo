"""The sentence-embedding model mojo_embed embeds with and the console
embeds search queries with: where it is downloaded from, its files, and the
hash of its weights that names its revision (`model_rev`).

A missing file comes from the stack's own bucket when it has a copy
(`mirror_of`: `<bucket of MORCA_WAREHOUSE>/models/...`), and otherwise from
Hugging Face, after which it is copied to the bucket, so a stack downloads
from Hugging Face once."""

from std.os import getenv, makedirs, remove, stat
from std.os.path import exists
from std.time import perf_counter_ns

from objectstore.fileio import FileIOResolver

from embedtext import fnv64, hex64
from fetch import get_bytes


comptime DEFAULT_MODEL = "build/models/bge-small-en-v1.5"
comptime HF_REV = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
"""The Hugging Face commit of BAAI/bge-small-en-v1.5 downloaded."""
comptime DEFAULT_URL = "https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/" + HF_REV
"""Where a missing model is downloaded from: Hugging Face, pinned to a
revision (MOJO_EMBED_MODEL_URL to change it)."""
comptime MIRROR_PATH = "models/bge-small-en-v1.5/" + HF_REV
"""Where in the bucket `mirror_of` keeps the model."""
comptime DEFAULT_REV = "bbddccb7d85cc5e6"
"""`model_rev` of DEFAULT_URL's weights; a download must hash to
MOJO_EMBED_MODEL_REV (this by default)."""
comptime QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
"""What bge models want before a short search query (not before the texts
searched)."""


def mirror_of(warehouse: String) -> String:
    """Where the stack keeps its copy of the model: MOJO_EMBED_MODEL_MIRROR,
    else `s3://<bucket>/models/bge-small-en-v1.5/<HF_REV>` for a warehouse in
    `s3://<bucket>/...`; empty (no copy) for a local warehouse, or with
    MOJO_EMBED_MODEL_URL set (a model of one's own)."""
    var m = getenv("MOJO_EMBED_MODEL_MIRROR")
    if m:
        return m
    if getenv("MOJO_EMBED_MODEL_URL") or not warehouse.startswith("s3://"):
        return String()
    var rest = String(warehouse[byte = 5 :])
    var slash = rest.find("/").or_else(-1)
    var bucket = rest if slash < 0 else String(rest[byte = : slash])
    return String("s3://", bucket, "/", MIRROR_PATH)


def ensure_model(dir: String) raises -> List[String]:
    """Fetches the files of the model missing from `dir`, from the stack's
    copy (`mirror_of`) when it has them, else from MOJO_EMBED_MODEL_URL, and
    checks that fetched weights hash to the expected revision. Files
    downloaded are then copied to the mirror (a failure to is logged, not
    raised). A directory that has them all is used as it is. Returns a line
    to log per file fetched."""
    var files: List[String] = [
        "config.json", "vocab.txt", "1_Pooling/config.json", "model.safetensors",
    ]
    var log = List[String]()
    var missing = List[String]()
    for ref f in files:
        if not exists(dir + "/" + f):
            missing.append(f)
    if len(missing) == 0:
        return log^
    var url = getenv("MOJO_EMBED_MODEL_URL", DEFAULT_URL)
    var mirror = mirror_of(getenv("MORCA_WAREHOUSE"))
    var io = FileIOResolver()
    var downloaded = List[String]()
    var src = url
    for ref f in missing:
        var path = dir + "/" + f
        var parent = String(path[byte = : path.rfind("/").or_else(-1)])
        makedirs(parent, exist_ok=True)
        var t0 = perf_counter_ns()
        # The whole body arrives before the file is opened, so a failed
        # download leaves no file behind; the weights are checked below.
        var body: List[UInt8]
        var from_mirror = False
        if mirror and io.exists(mirror + "/" + f):
            body = io.read_all(mirror + "/" + f)
            from_mirror = True
        else:
            body = get_bytes(url + "/" + f)
            downloaded.append(f)
        if from_mirror and f == "model.safetensors":
            src = mirror
        with open(path, "w") as out:
            out.write_bytes(Span(body))
        log.append(String(
            "fetched ", f, " (", len(body), " bytes) from ",
            mirror if from_mirror else url, " in ",
            Float64(perf_counter_ns() - t0) / 1e9, " s",
        ))
    if "model.safetensors" in missing:
        var want = getenv("MOJO_EMBED_MODEL_REV", DEFAULT_REV)
        var got = model_rev(dir)
        if got != want:
            remove(dir + "/model.safetensors")
            raise Error(
                src, "/model.safetensors hashes to ", got, ", expected ", want,
                " (MOJO_EMBED_MODEL_REV); removed",
            )
    if mirror and len(downloaded) > 0:
        try:
            for ref f in downloaded:
                var path = dir + "/" + f
                var data: List[UInt8]
                with open(path, "r") as inp:
                    data = inp.read_bytes(Int(stat(path).st_size))
                io.write(mirror + "/" + f, Span(data))
            log.append(String("copied ", len(downloaded), " files to ", mirror))
        except e:
            log.append(String("not copied to ", mirror, ": ", e))
    return log^


def model_rev(dir: String) raises -> String:
    """A hash of the model's weights, which names the model's version."""
    var b: List[UInt8]
    with open(dir + "/model.safetensors", "r") as f:
        b = f.read_bytes()
    return hex64(fnv64(Span(b)))
