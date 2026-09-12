defmodule Rail.Runs.Utils.PumpStreamTest do
  use ExUnit.Case, async: true

  import Rail.Runs.Utils.PumpStream

  @moduletag :tmp_dir

  test "yields complete lines and holds the trailing fragment", %{tmp_dir: tmp_dir} do
    stream = Path.join(tmp_dir, "stream.ndjson")
    File.write!(stream, "first\nsecond\nhalf ")

    assert {["first", "second"], offset, "half "} = pump_stream(stream, 0, "")
    assert offset == File.stat!(stream).size

    # The writer finishes the line, and the held fragment leads the next read.
    File.write!(stream, "a line\n", [:append])

    assert {["half a line"], _offset, ""} = pump_stream(stream, offset, "half ")
  end

  test "final: true flushes the held partial line", %{tmp_dir: tmp_dir} do
    stream = Path.join(tmp_dir, "stream.ndjson")
    File.write!(stream, "complete line\n")
    size = File.stat!(stream).size

    assert pump_stream(stream, size, "unflushed_partial", final: true) == {["unflushed_partial"], size, ""}
  end

  test "holds the partial line and the offset when nothing new was written", %{tmp_dir: tmp_dir} do
    stream = Path.join(tmp_dir, "stream.ndjson")
    File.write!(stream, "complete line\n")
    size = File.stat!(stream).size

    assert pump_stream(stream, size, "partial") == {[], size, "partial"}
  end

  test "holds the partial line when the file does not exist" do
    assert pump_stream("/tmp/nonexistent_file_xyz", 0, "partial") == {[], 0, "partial"}
  end

  test "decodes invalid bytes leniently", %{tmp_dir: tmp_dir} do
    stream = Path.join(tmp_dir, "stream.ndjson")
    File.write!(stream, <<"bad ", 255, "\n">>)

    assert {[line], _offset, ""} = pump_stream(stream, 0, "")
    assert line =~ "�"
  end
end
