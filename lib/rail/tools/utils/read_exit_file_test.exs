defmodule Rail.Tools.Utils.ReadExitFileTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.ReadExitFile

  alias Rail.Tools.Schemas.OsProcess

  setup do
    dir = Path.join(System.tmp_dir!(), "read_exit_file_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{os_process: %OsProcess{stream_path: Path.join(dir, "proc.log")}}
  end

  test "reads the status the command wrote", %{os_process: os_process} do
    File.write!(OsProcess.exit_path(os_process), "3\n")

    assert read_exit_file(os_process) == 3
  end

  test "is nil when the command never wrote one", %{os_process: os_process} do
    assert read_exit_file(os_process) == nil
  end

  test "is nil when what it wrote is not a number", %{os_process: os_process} do
    File.write!(OsProcess.exit_path(os_process), "")

    assert read_exit_file(os_process) == nil
  end
end
