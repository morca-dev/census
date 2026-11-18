# The input text, hashes and vector bytes of mojo.repo_embeddings, and a
# batch of rows read back as written. No model needed.

from std.testing import assert_equal, assert_not_equal, TestSuite

from embedtext import (
    EmbedRow,
    embed_batch,
    embed_rows,
    fnv64,
    hex64,
    input_hash,
    repo_input,
    vector_bytes,
    vector_of,
)


def test_repo_input() raises:
    assert_equal(
        repo_input("someone/mojo-sqlite_bindings", "SQLite bindings for Mojo", ["mojo", "sqlite"]),
        "mojo sqlite bindings: SQLite bindings for Mojo. Topics: mojo, sqlite",
    )
    assert_equal(repo_input("a/b", "  Done!  ", []), "b: Done!")
    assert_equal(repo_input("a/b", "", []), "b")
    assert_equal(repo_input("a/b", "", ["x"]), "b Topics: x")


def test_hashes() raises:
    # FNV-1a 64 of "a" is af63dc4c8601ec8c.
    assert_equal(hex64(fnv64(String("a").as_bytes())), "af63dc4c8601ec8c")
    var h = input_hash("text", "rev1")
    assert_equal(h.byte_length(), 16)
    assert_equal(h, input_hash("text", "rev1"))
    assert_not_equal(h, input_hash("text", "rev2"))
    assert_not_equal(h, input_hash("text2", "rev1"))
    # The separator keeps ("ab", "c") apart from ("a", "bc").
    assert_not_equal(input_hash("ab", "c"), input_hash("a", "bc"))


def test_vector_bytes() raises:
    var v: List[Float32] = [9.0, 1.5, -0.25, 3.0e-8, 7.0]
    var b = vector_bytes(v, 1, 3)
    assert_equal(len(b), 12)
    # 1.5 is 0x3fc00000, little-endian.
    assert_equal(b[0], 0x00)
    assert_equal(b[2], 0xC0)
    assert_equal(b[3], 0x3F)
    var back = vector_of(b)
    assert_equal(len(back), 3)
    assert_equal(back[0], 1.5)
    assert_equal(back[1], -0.25)
    assert_equal(back[2], 3.0e-8)


def test_batch_round_trip() raises:
    var v: List[Float32] = [0.6, 0.8]
    var rows = List[EmbedRow]()
    rows.append(EmbedRow("a/b", "bge-small-en-v1.5", "r1", "h1", "b: x", 2, vector_bytes(v, 0, 2), 1_700_000_000_000_000))
    rows.append(EmbedRow("c/d", "bge-small-en-v1.5", "r1", "h2", "d", 2, vector_bytes(v, 0, 2), 1_700_000_000_000_001))
    var back = embed_rows(embed_batch(rows))
    assert_equal(len(back), 2)
    assert_equal(back[1].repo, "c/d")
    assert_equal(back[0].input, "b: x")
    assert_equal(back[0].dim, 2)
    assert_equal(back[1].embedded_at, 1_700_000_000_000_001)
    var w = vector_of(back[0].vector)
    assert_equal(w[0], Float32(0.6))
    assert_equal(w[1], Float32(0.8))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
