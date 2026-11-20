"""Reading columns of a `RecordBatch` in place, by name."""

from parquet import RecordBatch
from parquet.arrow import ArrayData


def col(batch: RecordBatch, name: String) raises -> Int:
    """The index of the column called `name`."""
    for i in range(len(batch.roots)):
        if batch.column(i).name == name:
            return i
    raise Error("no column ", name)


@always_inline
def is_valid(a: ArrayData, row: Int) -> Bool:
    if a.null_count == 0 or len(a.validity) == 0:
        return True
    return Bool((a.validity[row >> 3] >> UInt8(row & 7)) & 1)


@always_inline
def str_range(a: ArrayData, row: Int) -> Tuple[Int, Int]:
    """Where row `row` of a string column sits in `a.values`."""
    if len(a.large_offsets) > 0:
        return (Int(a.large_offsets[row]), Int(a.large_offsets[row + 1]))
    return (Int(a.offsets[row]), Int(a.offsets[row + 1]))


def str_at(a: ArrayData, row: Int) -> String:
    """Row `row` of a string column, or "" for a null."""
    if not is_valid(a, row):
        return String()
    var r = str_range(a, row)
    return String(StringSpan(unsafe_from_utf8=Span(a.values)[r[0] : r[1]]))


def i64_at(a: ArrayData, row: Int) -> Int64:
    """Row `row` of a long or timestamp column, or 0 for a null."""
    if not is_valid(a, row):
        return 0
    var p = a.values.unsafe_ptr().unsafe_bitcast[Int64]()
    return p[unsafe_offset=row]


def i32_at(a: ArrayData, row: Int) -> Int64:
    """Row `row` of an int or `date` column (days), or 0 for a null."""
    if not is_valid(a, row):
        return 0
    var p = a.values.unsafe_ptr().unsafe_bitcast[Int32]()
    return Int64(p[unsafe_offset=row])


def f64_at(a: ArrayData, row: Int) -> Float64:
    """Row `row` of a double column, or 0 for a null."""
    if not is_valid(a, row):
        return 0
    var p = a.values.unsafe_ptr().unsafe_bitcast[Float64]()
    return p[unsafe_offset=row]


def bool_at(a: ArrayData, row: Int) -> Bool:
    """Row `row` of a boolean column (bit-packed), or False for a null."""
    if not is_valid(a, row):
        return False
    return Bool((a.values[row >> 3] >> UInt8(row & 7)) & 1)


def strs_at(batch: RecordBatch, column: Int, row: Int) -> List[String]:
    """Row `row` of a `list<string>` column; empty for a null."""
    var out = List[String]()
    ref a = batch.column(column)
    if not is_valid(a, row) or len(a.children) == 0:
        return out^
    var r = str_range(a, row)
    ref items = batch.arena.nodes[a.children[0]]
    for k in range(r[0], r[1]):
        out.append(str_at(items, k))
    return out^


def has_col(batch: RecordBatch, name: String) -> Bool:
    for i in range(len(batch.roots)):
        if batch.column(i).name == name:
            return True
    return False
