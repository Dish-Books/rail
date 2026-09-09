defmodule Rail.ToolEnvTest do
  use Rail.DataCase, async: false

  alias Rail.ToolEnv

  setup do
    ToolEnv.reset()

    on_exit(fn ->
      ToolEnv.reset()
    end)

    :ok
  end

  test "init/0 and initialize/0 resolve PATH idempotently" do
    assert :ok = ToolEnv.init()
    path1 = ToolEnv.path()
    assert byte_size(path1) > 0
    assert String.contains?(path1, "/bin")

    assert :ok = ToolEnv.initialize()
    assert ToolEnv.path() == path1
  end

  test "path/0 computes fallback if init never ran" do
    assert byte_size(ToolEnv.path()) > 0
  end

  test "debug_set_path/1 overrides PATH and clears cache" do
    ToolEnv.debug_set_path("/custom/bin:/another/bin")
    assert ToolEnv.path() == "/custom/bin:/another/bin"
  end

  test "resolve/1 returns path unchanged if it contains a slash" do
    assert ToolEnv.resolve("/usr/bin/custom_tool") == "/usr/bin/custom_tool"
    assert ToolEnv.resolve("./relative_tool") == "./relative_tool"
  end

  test "resolve/1 finds existing executable and caches it" do
    resolved = ToolEnv.resolve("sh")
    assert byte_size(resolved) > 0
    assert String.ends_with?(resolved, "/sh")
    assert File.exists?(resolved)

    assert ToolEnv.resolve("sh") == resolved
  end

  test "resolve/1 ignores directories or non-executable files" do
    temp_dir = System.tmp_dir!()
    non_exec = Path.join(temp_dir, "non_exec_test_file.sh")
    File.write!(non_exec, "#!/bin/sh\n")
    File.chmod!(non_exec, 0o644)

    ToolEnv.debug_set_path(temp_dir)
    assert ToolEnv.resolve("non_exec_test_file.sh") == "non_exec_test_file.sh"

    File.rm(non_exec)
  end

  test "resolve/1 falls back to bare name if not found on PATH" do
    assert ToolEnv.resolve("definitely_not_a_real_binary_xyz_123") ==
             "definitely_not_a_real_binary_xyz_123"
  end

  test "env/0 and env/1 return merged environment map" do
    env0 = ToolEnv.env()
    assert Map.has_key?(env0, "PATH")
    assert env0["PATH"] == ToolEnv.path()

    env1 = ToolEnv.env(%{"FOO" => "bar", "NUM" => 42})
    assert env1["FOO"] == "bar"
    assert env1["NUM"] == "42"
    assert env1["PATH"] == ToolEnv.path()

    env_override = ToolEnv.env(%{"PATH" => "/custom/override"})
    assert env_override["PATH"] == "/custom/override"

    assert ToolEnv.env(nil) == env0
  end

  test "run/2,3 executes command with resolved path and merged env" do
    assert {output, 0} = ToolEnv.run("echo", ["hello toolenv"])
    assert String.trim(output) == "hello toolenv"

    assert {output_env, 0} =
             ToolEnv.run("sh", ["-c", "echo $CUSTOM_VAR"], env: %{"CUSTOM_VAR" => "axis_test"})

    assert String.trim(output_env) == "axis_test"

    # Test with working_directory and into
    assert {output_wd, 0} =
             ToolEnv.run("pwd", [], working_directory: System.tmp_dir!(), into: "")

    assert File.stat!(String.trim(output_wd)).inode == File.stat!(System.tmp_dir!()).inode

    # Test with cd
    assert {output_cd, 0} =
             ToolEnv.run("pwd", [], cd: System.tmp_dir!())

    assert File.stat!(String.trim(output_cd)).inode == File.stat!(System.tmp_dir!()).inode

    assert {output_err, _code} =
             ToolEnv.run("sh", ["-c", "echo err_msg >&2"], stderr_to_stdout: true)

    assert String.contains?(output_err, "err_msg")
  end

  test "calculate_path merges and deduplicates in exact order" do
    home = System.get_env("HOME") || "/Users/test"
    merged = ToolEnv.calculate_path("/shell/bin:/common/bin")

    segments = String.split(merged, ":")

    assert hd(segments) == "/shell/bin"
    assert "/common/bin" in segments
    assert "#{home}/.local/bin" in segments
    assert "#{home}/bin" in segments
    assert "/opt/homebrew/bin" in segments
    assert "/usr/bin" in segments
    assert "/bin" in segments

    assert length(segments) == length(Enum.uniq(segments))

    # Handles nil shell_path and empty sys_path
    merged_empty = ToolEnv.calculate_path(nil, "")
    assert String.contains?(merged_empty, "/usr/bin")
  end

  test "parse_shell_path extracts path only from __axis_path__ marker" do
    stdout = """
    zsh: welcome to test shell
    some other rc noise
    __axis_path__/custom/shell/path:/usr/bin
    trailing message
    """

    assert ToolEnv.parse_shell_path(stdout) == "/custom/shell/path:/usr/bin"
    assert ToolEnv.parse_shell_path("no marker here") == nil
    assert ToolEnv.parse_shell_path(nil) == nil
  end

  test "login_shell_path/1 handles nil, blank, and invalid shells" do
    assert ToolEnv.login_shell_path(nil) == nil
    assert ToolEnv.login_shell_path("") == nil
    assert ToolEnv.login_shell_path("/nonexistent/fake_shell_xyz") == nil
  end
end
