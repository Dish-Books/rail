defmodule Rail.Runs.Utils.DrainErrFileTest do
  use ExUnit.Case, async: true

  import Rail.Runs.Utils.DrainErrFile

  @moduletag :tmp_dir

  test "returns trimmed non-empty lines", %{tmp_dir: tmp_dir} do
    err_path = Path.join(tmp_dir, "stream.ndjson.err")
    File.write!(err_path, "  boom  \n\n  second line\n")

    assert drain_err_file(err_path) == ["boom", "second line"]
  end

  test "returns [] when the file is missing", %{tmp_dir: tmp_dir} do
    assert drain_err_file(Path.join(tmp_dir, "absent.err")) == []
  end

  test "returns [] when the path cannot be read", %{tmp_dir: tmp_dir} do
    assert drain_err_file(tmp_dir) == []
  end
end
