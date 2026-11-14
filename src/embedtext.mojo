"""The rows of `mojo.repo_embeddings` (mojo_embed): what text a repository
is embedded from, the hashes that say when to embed it again, and the
vector as bytes.
"""

from std.memory import bitcast

from morca.tables import BatchBuilder
from parquet import RecordBatch

from cols import col, i32_at, i64_at, str_at, str_range, is_valid
from lake import repo_embeddings_schema


@fieldwise_init
struct EmbedRow(Copyable, Movable):
    var repo: String
    var model: String
    var model_rev: String
    var input_hash: String
    var input: String
    var dim: Int
    var vector: List[UInt8]  # dim float32 values, little-endian
    var embedded_at: Int64  # microseconds


def repo_input(repo: String, description: String, topics: List[String]) -> String:
    """The text a repository is embedded from: its name with `-` and `_` as
    spaces, its description and its topics, for example
    "mojo sqlite: SQLite bindings for Mojo. Topics: mojo, sqlite"."""
    var slash = repo.find("/")
    var name = String(repo[byte = slash + 1 :]) if slash >= 0 else repo
    name = name.replace("-", " ").replace("_", " ")
    var out = name^
    var d = String(description.strip())
    if d.byte_length() > 0:
        out += ": "
        out += d
        if not (d.endswith(".") or d.endswith("!") or d.endswith("?")):
            out += "."
    if len(topics) > 0:
        out += " Topics: "
        for i in range(len(topics)):
            if i > 0:
                out += ", "
            out += topics[i]
    return out^


def fnv64(data: Span[UInt8, _], seed: UInt64 = 0xCBF29CE484222325) -> UInt64:
    """FNV-1a, 64 bits."""
    var h = seed
    for b in data:
        h ^= UInt64(b)
        h *= 0x100000001B3
    return h


def hex64(v: UInt64) -> String:
    comptime digits = "0123456789abcdef"
    var out = String()
    for i in range(15, -1, -1):
        out += digits[byte = Int((v >> UInt64(4 * i)) & 15)]
    return out^


def input_hash(input: String, model_rev: String) -> String:
    """Changes when the text or the model does: a run embeds a repository
    again exactly when its stored hash differs."""
    var h = fnv64(input.as_bytes())
    h = fnv64(String("\x00").as_bytes(), h)
    return hex64(fnv64(model_rev.as_bytes(), h))


def vector_bytes(v: List[Float32], start: Int, dim: Int) -> List[UInt8]:
    """v[start : start + dim] as little-endian float32 bytes."""
    var out = List[UInt8](capacity=4 * dim)
    for i in range(start, start + dim):
        var bits = bitcast[DType.uint32](v[i])
        out.append(UInt8(bits & 0xFF))
        out.append(UInt8((bits >> 8) & 0xFF))
        out.append(UInt8((bits >> 16) & 0xFF))
        out.append(UInt8((bits >> 24) & 0xFF))
    return out^


def vector_of(b: List[UInt8]) -> List[Float32]:
    """The inverse of `vector_bytes`."""
    var out = List[Float32](capacity=len(b) // 4)
    for i in range(0, len(b) - 3, 4):
        var bits = (
            UInt32(b[i])
            | (UInt32(b[i + 1]) << 8)
            | (UInt32(b[i + 2]) << 16)
            | (UInt32(b[i + 3]) << 24)
        )
        out.append(bitcast[DType.float32](bits))
    return out^


def _bytes_at(b: RecordBatch, column: Int, row: Int) -> List[UInt8]:
    ref a = b.column(column)
    var out = List[UInt8]()
    if not is_valid(a, row):
        return out^
    var r = str_range(a, row)
    for i in range(r[0], r[1]):
        out.append(a.values[i])
    return out^


def embed_rows(b: RecordBatch) raises -> List[EmbedRow]:
    """The rows of a scanned `mojo.repo_embeddings` batch."""
    var c = List[Int]()
    for name in [
        "repo", "model", "model_rev", "input_hash", "input", "dim", "vector",
        "embedded_at",
    ]:
        c.append(col(b, name))
    var out = List[EmbedRow]()
    for r in range(b.num_rows):
        out.append(
            EmbedRow(
                str_at(b.column(c[0]), r),
                str_at(b.column(c[1]), r),
                str_at(b.column(c[2]), r),
                str_at(b.column(c[3]), r),
                str_at(b.column(c[4]), r),
                Int(i32_at(b.column(c[5]), r)),
                _bytes_at(b, c[6], r),
                i64_at(b.column(c[7]), r),
            )
        )
    return out^


def embed_batch(rows: List[EmbedRow]) raises -> RecordBatch:
    var b = BatchBuilder(repo_embeddings_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        b.add_str(cs[1], r.model)
        b.add_str(cs[2], r.model_rev)
        b.add_str(cs[3], r.input_hash)
        b.add_str(cs[4], r.input)
        b.add_int(cs[5], Int64(r.dim))
        b.add_bytes(cs[6], Span(r.vector))
        b.add_int(cs[7], r.embedded_at)
    return b^.build()
