"""Finding libraries: a query's match score against a repository, and the
families the versions chart draws one line for."""

from versions import compare_versions, version_key


def _hex(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 87
    if c >= 65 and c <= 70:
        return Int(c) - 55
    return -1


def url_decode(s: String) -> String:
    """A query-string value with `+` and `%XX` decoded (flare leaves it raw)."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == UInt8(ord("+")):
            out.append(32)
        elif c == UInt8(ord("%")) and i + 2 < len(b) and _hex(b[i + 1]) >= 0 and _hex(b[i + 2]) >= 0:
            out.append(UInt8(_hex(b[i + 1]) * 16 + _hex(b[i + 2])))
            i += 2
        else:
            out.append(c)
        i += 1
    return String(from_utf8_lossy=out)


def url_encode(s: String) -> String:
    """`s` as a query-string value: letters, digits and `-._~` as they are,
    every other byte as `%XX`."""
    comptime HEX = "0123456789ABCDEF"
    var out = String()
    for c in s.as_bytes():
        if (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("-")) or c == UInt8(ord(".")) or c == UInt8(ord("_")) or c == UInt8(ord("~"))
        ):
            out += chr(Int(c))
        else:
            out.write("%", HEX[byte = Int(c >> 4)], HEX[byte = Int(c & 15)])
    return out^


def search_score(
    repo: String,
    description: String,
    query: String,
    topics: List[String] = List[String](),
) -> Int:
    """0 for no match, else higher for better: the name (the part after
    `owner/`) equal to the query, then starting with it, then containing it,
    then a GitHub topic equal to it, then `owner/name` containing it, then a
    topic containing it, then the description. Case-insensitive; an empty
    query matches nothing."""
    var q = String(query.strip()).lower()
    if q.byte_length() == 0:
        return 0
    var full = repo.lower()
    var name = full
    var slash = full.find("/")
    if slash >= 0:
        name = String(full[byte = slash + 1 :])
    if name == q or full == q:
        return 100
    if name.startswith(q):
        return 80
    if q in name:
        return 60
    for t in topics:
        if t.lower() == q:
            return 50
    if q in full:
        return 40
    for t in topics:
        if q in t.lower():
            return 30
    if q in description.lower():
        return 20
    return 0


def names_score(
    repo: String,
    aliases: List[String],
    description: String,
    query: String,
    topics: List[String] = List[String](),
) -> Int:
    """`search_score` over a repository's current name (`repo`) and the
    names it had (`aliases`, #181), the best of them: an old name matches as
    a name, one point below the same match on the current name."""
    var best = search_score(repo, description, query, topics)
    for ref a in aliases:
        var sc = search_score(a, String(), query) - 1
        if sc > best:
            best = sc
    return best


def version_family(v: String) -> String:
    """`24.x`, `25.x`, `0.25.x`, `0.26.x`, `1.x`: the line of releases `v` is
    on (a calendar 26.1 is 0.26.x); a string that isn't a version is its own family, `other`."""
    if len(version_key(v)) == 0:
        return String("other")
    var parts = v.strip().split(".")
    if len(parts) > 1 and String(parts[0]) == "0":
        return String("0.", parts[1], ".x")
    var era = version_key(v)[0]
    if era >= 26 and era < 100:
        # 26.1 is the 0.26.1 release under its calendar name.
        return String("0.", era, ".x")
    return String(parts[0], ".x")


def sort_families(mut fs: List[String], mut oldest: List[String]):
    """`fs` in Mojo's order; `oldest[i]` is the earliest version seen in
    `fs[i]`, which orders them (`other` last)."""
    for i in range(1, len(fs)):
        var j = i
        while j > 0 and (
            (fs[j - 1] == "other" and fs[j] != "other")
            or (
                fs[j] != "other"
                and fs[j - 1] != "other"
                and compare_versions(oldest[j - 1], oldest[j]) > 0
            )
        ):
            fs.swap_elements(j - 1, j)
            oldest.swap_elements(j - 1, j)
            j -= 1


def version_bucket(v: String) -> String:
    """`pre-1.0` for every version before Mojo 1.0 (24.x, 25.x, 0.25.x, 0.26.x,
    the calendar 26.1), else `<major>.<minor>` (`1.0`, `1.2`; a nightly
    `1.2.0.dev2026101905` is on `1.2`); a string that isn't a version is
    `other`."""
    var key = version_key(v)
    if len(key) == 0:
        return String("other")
    if key[0] < 100:
        return String("pre-1.0")
    return String(key[0] - 100, ".", key[1])


def bucket_rank(b: String) -> Int:
    """Where bucket `b` sits in Mojo's order: `pre-1.0`, then `1.0`, `1.1`,
    ..., then `other`, `unknown`."""
    if b == "pre-1.0":
        return 0
    if b == "other":
        return 1_000_000_000
    if b == "no-manifest":
        return 1_500_000_000
    if b == "unknown":
        return 2_000_000_000
    var dot = b.find(".")
    if dot < 0:
        return 1_000_000_000
    try:
        return Int(String(b[byte=:dot])) * 100_000 + Int(String(b[byte = dot + 1 :])) + 1
    except:
        return 1_000_000_000


def sort_buckets(mut bs: List[String], mut oldest: List[String]):
    """`bs` in Mojo's order (`bucket_rank`); `oldest` is swapped along."""
    for i in range(1, len(bs)):
        var j = i
        while j > 0 and bucket_rank(bs[j - 1]) > bucket_rank(bs[j]):
            bs.swap_elements(j - 1, j)
            oldest.swap_elements(j - 1, j)
            j -= 1


def version_matches(want: String, bucket: String, family: String) -> Bool:
    """Whether a repo on `bucket` (and the old `family`) passes the
    `?version=` value `want`: a bucket (`1.2`, `pre-1.0`, `unknown`) or one of
    the old families (`1.x`, `0.26.x`, `25.x`), which old links still use."""
    return want == bucket or want == family
