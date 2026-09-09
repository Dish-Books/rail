defmodule Rail.Backends.ProbesTest do
  use Rail.DataCase, async: true

  alias Rail.Backends.Probes

  test "default_path_validator/1 validates existing executable regular files" do
    sh_path = System.find_executable("sh")
    assert Probes.default_path_validator(sh_path)

    refute Probes.default_path_validator("")
    refute Probes.default_path_validator(nil)
    refute Probes.default_path_validator("/non/existent/path/binary")

    refute Probes.default_path_validator("/invalid\0path")

    temp_file = Path.join(System.tmp_dir!(), "non_exec_#{System.unique_integer([:positive])}.txt")
    File.write!(temp_file, "hello")
    File.chmod!(temp_file, 0o644)
    refute Probes.default_path_validator(temp_file)
    File.rm!(temp_file)
  end

  test "default_config_file_reader/1 reads existing file or returns error" do
    temp_file = Path.join(System.tmp_dir!(), "config_#{System.unique_integer([:positive])}.json")
    File.write!(temp_file, ~s({"key": "value"}))

    expected = ~s({"key": "value"})
    assert {:ok, ^expected} = Probes.default_config_file_reader(temp_file)

    assert {:error, :enoent} = Probes.default_config_file_reader("/non/existent/config.json")
    assert {:error, :badarg} = Probes.default_config_file_reader("/invalid\0path")
    File.rm!(temp_file)
  end
end
