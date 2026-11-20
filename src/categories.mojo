"""Repo categories from mojo.repo_embeddings, approximate: a few rules on the
description, else a vote of the repo's nearest hand-labelled repos.

1. A repo whose embedded text has no description (only its name) is
   `other`: there is nothing to tell it by.
2. "bindings for/to", "wrapper for/around" or "via FFI" is `ffi`, or `games`
   when it binds a graphics library (raylib, SDL, OpenGL, Vulkan, GLFW, wgpu).
3. "port of" is `tooling`: most of these are ports of Python libraries.
4. Otherwise the `VOTERS` labelled repos (`examples`) nearest it vote,
   weighted by cosine, on vectors centered on the mean of all repos (which
   takes out what every Mojo repo's text shares).

Checked by hand on 110 repos none of `examples` are: 81% agree on 80, and 24
of a further 30 labelled before looking (80%). Changing `examples` or the
rules is a new `CATEGORIES_VERSION`; it labels everything again at the
console's next build, with no new embeddings.
"""

from similar import Embeddings


comptime CATEGORIES_VERSION = 1
comptime VOTERS = 7

def category_keys() -> List[String]:
    """The categories, in the order the filters list them."""
    return ["ml", "ffi", "tooling", "learning", "games", "web", "other"]


def _titles() -> List[String]:
    return [
        "ML and inference", "Bindings and FFI", "Libraries and tools",
        "Learning and examples", "Games and graphics", "Web and networking",
        "Other",
    ]

def examples() -> List[String]:
        """`<category> <repo>`: the hand-labelled repos that vote."""
    return [
        "ffi BenWibking/mojo-amrex",
        "ffi Conobi/re2-mojo",
        "ffi CyanStarlight/mojo-glfw-bindings",
        "ffi Hammad-hab/Mojo-GTK",
        "ffi Phelsong/mojo-wayland",
        "ffi codetalcott/napi-mojo",
        "ffi ExtraMojo/zipprs-llm",
        "ffi ez-mojo/uuid",
        "ffi DataBooth/py-run-mojo",
        "web Jensen-holm/FireTCP",
        "web atsentia/mojo-redis",
        "web atsentia/mojo-websocket",
        "web codetalcott/mojo-http",
        "web conorbronsdon/mojo-redis",
        "web dodo-mojo/dodo",
        "web jmikaelr/mojoreq",
        "web lee101/mojo-h11",
        "web lee101/mojo-httptools",
        "web msaelices/mojo-websockets",
        "web magmalake/flight.mojo",
        "web Mosaad-M/tls",
        "games AtharvBhat/mojo-raytracer",
        "games RomanRobot/game-master",
        "games Zbornak/morabaraba",
        "games andrew-suprun/Game-of-Stones",
        "games HamxAnwar/guesser_game_mojo",
        "games MojoGameDevs/sdl-mojo",
        "games Ryul0rd/vulkan-mojo",
        "games MojoGameDevs/opengl-mojo",
        "games bertaveira/mojosplat",
        "games bhansconnect/mojo-raytracer",
        "games gonsolo/mojo_gpu_raytracer",
        "ml Benny-Nottonson/voodoo",
        "ml CodeAlexx/mojodiffusion",
        "ml SergiuDeveloper/mojo-tensor",
        "ml Terapines/llama3.mojo",
        "ml TheAgaveFairy/mojollm",
        "ml basalt-org/basalt",
        "ml big-yellow-duck/mojo_gemm_w4a16",
        "ml dorjeduck/llm.mojo",
        "ml ethqnol/strata-mojo",
        "ml itsdevcoffee/mojo-visage",
        "ml atsentia/mojo-tokenizer",
        "ml amarbaro/mojo-tokenizers",
        "learning Al3xPhys/AOC2015Mojo",
        "learning AndreaDac/advent-of-code2024",
        "learning Brianoksoftware/learning-mojo",
        "learning DSNJTurtle/aoc_2024_mojo",
        "learning Ivo-Balbaert/Mojo_in_Action",
        "learning JeffExec/mojo-learning",
        "learning Maucalderondelab/mojo-python",
        "learning Netra-Srinivasan-McW/Mojo_Projects",
        "learning Sohoxic/Mojo-Programming",
        "learning AurelienTollard/mojo-gpu-puzzles",
        "learning amar-jay/first-mojo",
        "learning AIByJohannes/mojo-notebook",
        "tooling DataBooth/mojo-dotenv",
        "tooling DataBooth/mojo-ini",
        "tooling IbarraSamuel/motoml",
        "tooling Mojo-Numerics-and-Algorithms-group/NuMojo",
        "tooling Mosaad-M/mojo-pkg",
        "tooling ZacHooper/mojo-json",
        "tooling aarnphm/monpy",
        "tooling amarbaro/xmojo",
        "tooling atsentia/mojo-testing",
        "tooling atsentia/mojo-time",
        "tooling avitkauskas/mojo-datastructs",
        "tooling conorbronsdon/mojo-markdown",
        "tooling conorbronsdon/mojo-url",
        "tooling lee101/mojo-aenum",
        "tooling lee101/mojo-agate",
        "tooling lee101/mojo-apscheduler",
    ]


def category_title(key: String) -> String:
    var keys = category_keys()
    var titles = _titles()
    for i in range(len(keys)):
        if key == keys[i]:
            return titles[i]
    return key


def is_category(key: String) -> Bool:
    return key in category_keys()


def _has(s: String, part: StringSpan) -> Bool:
    return part in s


def by_rule(input: String) -> String:
    """The category the embedded text decides by itself, or "" when the
    vote should."""
    if not _has(input, ":") and not _has(input, "Topics"):
        return String("other")
    var t = input.lower()
    if (
        _has(t, "binding for") or _has(t, "bindings for") or _has(t, "binding to ")
        or _has(t, "bindings to ") or _has(t, "wrapper for") or _has(t, "wrapper around")
        or _has(t, "via ffi") or _has(t, "via c ffi")
    ):
        for g in ["raylib", "sdl", "opengl", "vulkan", "glfw", "wgpu"]:
            if _has(t, g):
                return String("games")
        return String("ffi")
    if t.startswith("port of ") or _has(t, " port of "):
        return String("tooling")
    return String()


def _unit(mut v: List[Float32]):
    var n = Float32(0)
    for x in v:
        n += x * x
    if n <= 0:
        return
    var s = 1 / (n ** 0.5)
    for i in range(len(v)):
        v[i] *= s


def categorize(e: Embeddings) -> Dict[String, String]:
    """Each repo of `e`: its category key."""
    var out = Dict[String, String]()
    var n = len(e.repos)
    var d = e.dim
    if n == 0 or d == 0:
        return out^
    var mean = List[Float32](length=d, fill=0)
    for i in range(n):
        for j in range(d):
            mean[j] += e.vecs[i * d + j]
    for j in range(d):
        mean[j] /= Float32(n)
    var centered = List[List[Float32]]()
    var at = Dict[String, Int]()
    for i in range(n):
        var v = List[Float32](length=d, fill=0)
        for j in range(d):
            v[j] = e.vecs[i * d + j] - mean[j]
        _unit(v)
        centered.append(v^)
        at[e.repos[i]] = i
    var ex_at = List[Int]()
    var ex_cat = List[String]()
    for ref line in examples():
        var parts = line.split(" ")
        var i = at.get(String(parts[1]), -1)
        if i >= 0:
            ex_at.append(i)
            ex_cat.append(String(parts[0]))
    for i in range(n):
        var rule = by_rule(e.inputs[i])
        if rule.byte_length() > 0 or len(ex_at) == 0:
            out[e.repos[i]] = rule if rule.byte_length() > 0 else String("other")
            continue
        # The VOTERS nearest examples, other than itself.
        var top_s = List[Float32]()
        var top_c = List[String]()
        for x in range(len(ex_at)):
            if ex_at[x] == i:
                continue
            var s = Float32(0)
            for j in range(d):
                s += centered[i][j] * centered[ex_at[x]][j]
            var p = len(top_s)
            while p > 0 and top_s[p - 1] < s:
                p -= 1
            if p < VOTERS:
                top_s.insert(p, s)
                top_c.insert(p, ex_cat[x])
                if len(top_s) > VOTERS:
                    _ = top_s.pop()
                    _ = top_c.pop()
        var votes = Dict[String, Float32]()
        for x in range(len(top_s)):
            votes[top_c[x]] = votes.get(top_c[x], 0) + top_s[x]
        var best = String("other")
        var best_v = Float32(-1e30)
        # In category_keys' order, so a tie always goes the same way.
        for ref key in category_keys():
            var v = votes.get(key, Float32(-1e30))
            if v > best_v:
                best_v = v
                best = key
        out[e.repos[i]] = best^
    return out^
