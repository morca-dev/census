"""Embeds every Mojo repository's name, description and topics into
mojo.repo_embeddings, for similar repositories, semantic search and
categories on the console.

Daily partitions from 2026-11-10, each filled at 07:00 UTC, after
mojo_stats has refreshed the descriptions (06:00). A run reads every
repository's text (`mojo.repos`, overridden by its latest `ok` or
`renamed` row of `mojo.repo_stats`, a renamed repository under its new
name), and embeds only the repositories whose text or model
changed since their row was written: each row keeps `input_hash`, a hash of
the text and of the model's weights. The others keep their rows, and a run
with nothing new commits nothing. A repository gone from `mojo.repos` loses
its row.

The model is a sentence-transformers directory (magmalake/encoder.mojo):
MOJO_EMBED_MODEL, default build/models/bge-small-en-v1.5, recorded as
MOJO_EMBED_MODEL_NAME (default bge-small-en-v1.5). It is not in the
image: a run downloads the files the directory lacks (133 MB, a few
seconds) from MOJO_EMBED_MODEL_URL, BAAI/bge-small-en-v1.5 on Hugging Face
pinned to a revision, and checks the weights' hash. That hash is the rows'
`model_rev`, so new weights embed everything again on the next run (or at
once: `morca backfill --rerun mojo_embed <day>`).

The table is unpartitioned and rewritten whole by each commit, one
`overwrite` (`replace.replace_files`), as mojo_versions does.

    MOJO_EMBED_MODEL=build/models/bge-small-en-v1.5 \\
        ./build/mojo_embed run --partitions 2026-11-10
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from encoder import Encoder
from morca import Cron, Ctx, Current, Daily, Day, Mapped, Pipeline, Step, morca_main
from morca.civil import now
from morca.tables import ensure_table, scan, table

from cols import col, has_col, i32_at, str_at, strs_at
from embedtext import (
    EmbedRow,
    embed_batch,
    embed_rows,
    input_hash,
    repo_input,
    vector_bytes,
)
from lake import REPOS, REPO_EMBEDDINGS, REPO_STATS, repo_embeddings_schema
from replace import replace_files
from embedmodel import DEFAULT_MODEL, ensure_model, model_rev

comptime BATCH = 32


@fieldwise_init
struct _Text(Copyable, Movable):
    var name: String  # its current name: GitHub's after a rename (#181)
    var description: String
    var topics: List[String]
    var as_of: Int64  # the repo_stats day it came from; -1 for mojo.repos


def _texts(mut ctx: Ctx) raises -> Dict[String, _Text]:
    """Each repository of `mojo.repos` with its name, description and
    topics, the latest row of `mojo.repo_stats` with an answer (`ok`, or
    `renamed`: a renamed or transferred repository's new name and current
    text, #181) winning over the row of mojo.repos, which is as old as the
    repository's discovery."""
    var out = Dict[String, _Text]()
    var t = table(ctx, REPOS)
    for b in scan(ctx, t).to_batches():
        var c_repo = col(b, "repo")
        var c_desc = col(b, "description")
        var c_topics = col(b, "topics") if has_col(b, "topics") else -1
        for r in range(b.num_rows):
            var topics = strs_at(b, c_topics, r) if c_topics >= 0 else List[String]()
            var repo = str_at(b.column(c_repo), r)
            out[repo] = _Text(repo, str_at(b.column(c_desc), r), topics^, -1)
    var stats: Optional[type_of(t)] = None
    try:
        stats = table(ctx, REPO_STATS)
    except e:
        ctx.log(String(REPO_STATS, " not read (", e, "); using ", REPOS, " alone"))
    if stats:
        for b in scan(ctx, stats.value()).to_batches():
            var c_repo = col(b, "repo")
            var c_as_of = col(b, "as_of")
            var c_state = col(b, "state")
            var c_desc = col(b, "description")
            var c_topics = col(b, "topics")
            var c_new = col(b, "renamed_to")
            for r in range(b.num_rows):
                var repo = str_at(b.column(c_repo), r)
                var state = str_at(b.column(c_state), r)
                if repo not in out or (state != "ok" and state != "renamed"):
                    continue
                var as_of = i32_at(b.column(c_as_of), r)
                if as_of <= out[repo].as_of:
                    continue
                var name = str_at(b.column(c_new), r) if state == "renamed" else repo
                out[repo] = _Text(
                    name if name.byte_length() > 0 else repo,
                    str_at(b.column(c_desc), r), strs_at(b, c_topics, r), as_of,
                )
    return out^


def embed(mut ctx: Ctx, d: Day) raises -> Int:
    """Embeds the repositories whose text or model changed and rewrites
    mojo.repo_embeddings with them and the unchanged rows.
    Returns the number of repositories embedded."""
    var dir = getenv("MOJO_EMBED_MODEL", DEFAULT_MODEL)
    var model = getenv("MOJO_EMBED_MODEL_NAME", "bge-small-en-v1.5")
    for ref line in ensure_model(dir):
        ctx.log(line)
    var rev = model_rev(dir)
    var t = ensure_table(ctx, REPO_EMBEDDINGS, repo_embeddings_schema())

    var texts = _texts(ctx)
    var repos = List[String]()
    for e in texts.items():
        repos.append(e.key)
    sort(repos)

    # The current rows, and the files they are in: the commit below removes
    # every file, so the rows read must add up to what the files hold.
    var old = Dict[String, EmbedRow]()
    var files = List[String]()
    var file_rows = Int64(0)
    var read_rows = 0
    if t.metadata.has_current_snapshot:
        for task in scan(ctx, t).plan_files():
            files.append(task.data_file.file_path)
            file_rows += task.data_file.record_count
        for b in scan(ctx, t).to_batches():
            for ref r in embed_rows(b):
                old[r.repo] = r.copy()
                read_rows += 1
        if Int64(read_rows) != file_rows:
            raise Error(
                REPO_EMBEDDINGS, ": read ", read_rows, " rows but its files hold ", file_rows,
            )

    var out = List[EmbedRow]()
    var todo = List[String]()
    var inputs = List[String]()
    var hashes = List[String]()
    for ref repo in repos:
        ref tx = texts[repo]
        var input = repo_input(tx.name, tx.description, tx.topics)
        var h = input_hash(input, rev)
        var prev = old.get(repo)
        if prev and prev.value().input_hash == h:
            out.append(prev.value().copy())
        else:
            todo.append(repo)
            inputs.append(input^)
            hashes.append(h^)
    var dropped = 0
    for e in old.items():
        if e.key not in texts:
            dropped += 1
    if len(todo) == 0 and dropped == 0 and read_rows == len(out):
        ctx.log(String(
            len(repos), " repositories, all embedded already with ", model,
            " ", rev, "; nothing to commit",
        ))
        return 0

    var embedded_at = now() * 1_000_000
    if len(todo) > 0:
        var t0 = perf_counter_ns()
        var enc = Encoder(dir)
        var load_s = Float64(perf_counter_ns() - t0) / 1e9
        t0 = perf_counter_ns()
        var v = enc.encode(inputs, BATCH)
        var s = Float64(perf_counter_ns() - t0) / 1e9
        var dim = enc.dim()
        for i in range(len(todo)):
            out.append(EmbedRow(
                todo[i], model, rev, hashes[i], inputs[i], dim,
                vector_bytes(v, i * dim, dim), embedded_at,
            ))
        ctx.log(String(
            len(todo), " repositories embedded with ", model, " ", rev,
            " (dim ", dim, ") in ", s, " s, ", Float64(len(todo)) / max(s, 1e-9),
            " a second; model loaded in ", load_s, " s",
        ))
    # One `overwrite` snapshot removing `files` and adding `out`; a retry
    # finds the commit its first attempt made. Safe because one run writes
    # the table at a time (max_runs 1).
    var id = replace_files(ctx, t, files, [embed_batch(out)])
    ctx.log(String(
        String(d), ": ", len(repos), " repositories, ", len(todo), " embedded, ",
        len(out) - len(todo), " kept, ", dropped, " dropped; ", REPO_EMBEDDINGS,
        " ", read_rows, " -> ", len(out), " rows; snapshot ", id,
    ))
    return len(todo)


# `Mapped`: once per partition, here a `Day`. No dista task: the encoder
# runs in the step's process, on all its cores.
comptime Embed = Step[
    "embed",
    Day,
    Int,
    embed,
    Mapped,
    retries=1,
    reads=[REPOS, REPO_STATS, REPO_EMBEDDINGS],
    # replaces=: a rerun rewrites these rows (replace.replace_files) rather than
    # adding them again, so `morca backfill --rerun` needs no --allow-append.
    # Under replaces=, a morca.tables `append` to them would replace whole
    # partitions, other keys' rows included: keep writing through replace_files.
    replaces=[REPO_EMBEDDINGS],
]
# Daily at 07:00 UTC, an hour after mojo_stats. A day's run embeds what
# changed since the last, so a missed day needs no catch-up.
comptime MojoEmbed = Pipeline[
    "mojo_embed",
    Embed,
    partitions=Daily["2026-11-10"],
    schedule=Cron["0 7 * * *"],
    fills=Current,
    catchup=False,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoEmbed]()
