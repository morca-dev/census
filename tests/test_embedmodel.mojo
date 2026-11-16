from std.os import makedirs, setenv, unsetenv
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true

from command import remove_tree
from embedmodel import MIRROR_PATH, ensure_model, mirror_of, model_rev


def test_mirror_of_bucket() raises:
    _ = unsetenv("MOJO_EMBED_MODEL_MIRROR")
    _ = unsetenv("MOJO_EMBED_MODEL_URL")
    assert_equal(
        mirror_of("s3://orca-dev-warehouse/warehouse"),
        String("s3://orca-dev-warehouse/", MIRROR_PATH),
    )
    assert_equal(mirror_of("s3://b"), String("s3://b/", MIRROR_PATH))
    assert_equal(mirror_of("build/warehouse"), "")


def test_mirror_of_overrides() raises:
    _ = setenv("MOJO_EMBED_MODEL_URL", "https://example.com/m")
    assert_equal(mirror_of("s3://b/w"), "")
    _ = setenv("MOJO_EMBED_MODEL_MIRROR", "/tmp/m")
    assert_equal(mirror_of("s3://b/w"), "/tmp/m")
    _ = unsetenv("MOJO_EMBED_MODEL_URL")
    _ = unsetenv("MOJO_EMBED_MODEL_MIRROR")


def test_fetches_from_mirror() raises:
    var root = String("build/test_embedmodel")
    # A run before this one left its model here, and nothing would be fetched.
    remove_tree(root)
    var mirror = root + "/mirror"
    var dir = root + "/model"
    makedirs(mirror + "/1_Pooling", exist_ok=True)
    for f in ["config.json", "vocab.txt", "1_Pooling/config.json", "model.safetensors"]:
        with open(mirror + "/" + f, "w") as out:
            out.write("contents of ", f)
    _ = setenv("MOJO_EMBED_MODEL_MIRROR", mirror)
    # Nothing to download from: everything has to come from the mirror.
    _ = setenv("MOJO_EMBED_MODEL_URL", "http://127.0.0.1:9/none")
    _ = setenv("MOJO_EMBED_MODEL_REV", model_rev(mirror))
    var log = ensure_model(dir)
    assert_equal(len(log), 4)
    assert_true(exists(dir + "/1_Pooling/config.json"))
    assert_equal(model_rev(dir), model_rev(mirror))
    assert_equal(len(ensure_model(dir)), 0)
    _ = unsetenv("MOJO_EMBED_MODEL_MIRROR")
    _ = unsetenv("MOJO_EMBED_MODEL_URL")
    _ = unsetenv("MOJO_EMBED_MODEL_REV")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
