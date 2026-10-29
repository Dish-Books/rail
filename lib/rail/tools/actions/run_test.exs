defmodule Rail.Tools.Actions.RunTest do
  # Not async: one test puts a stand-in git on PATH, which is the whole VM's.
  use ExUnit.Case, async: false

  alias Rail.Tools

  test "executes command with resolved path and merged env" do
    assert {output, 0} = Tools.run("echo", ["hello tools"])
    assert String.trim(output) == "hello tools"

    assert {output_env, 0} =
             Tools.run("sh", ["-c", "echo $CUSTOM_VAR"], env: %{"CUSTOM_VAR" => "rail_test"})

    assert String.trim(output_env) == "rail_test"
  end

  test "git never takes the index lock for a read, unless the caller says otherwise" do
    # Found on PATH ahead of the real one, it prints the variable git would have read.
    bin = Path.join(System.tmp_dir!(), "run_test_bin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "git"), "#!/bin/sh\nprintenv GIT_OPTIONAL_LOCKS\n")
    File.chmod!(Path.join(bin, "git"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf(bin)
    end)

    assert {"0\n", 0} = Tools.run("git", [])
    assert {"1\n", 0} = Tools.run("git", [], env: %{"GIT_OPTIONAL_LOCKS" => "1"})
    assert {"", 1} = Tools.run("sh", ["-c", "printenv GIT_OPTIONAL_LOCKS"])
  end

  test "honours working_directory, cd, into and stderr_to_stdout" do
    assert {output_wd, 0} =
             Tools.run("pwd", [], working_directory: System.tmp_dir!(), into: "")

    assert File.stat!(String.trim(output_wd)).inode == File.stat!(System.tmp_dir!()).inode

    assert {output_cd, 0} = Tools.run("pwd", [], cd: System.tmp_dir!())
    assert File.stat!(String.trim(output_cd)).inode == File.stat!(System.tmp_dir!()).inode

    assert {output_err, _code} =
             Tools.run("sh", ["-c", "echo err_msg >&2"], stderr_to_stdout: true)

    assert String.contains?(output_err, "err_msg")
  end

  test "a cd that is not a directory fails the run rather than reaching the port" do
    expected = "spawn: Could not cd to /not/a/real/directory\n"
    assert {^expected, 1} = Tools.run("echo", ["hi"], cd: "/not/a/real/directory")
  end

  test "a timeout returns the run's own result when the tool finishes in time" do
    assert {output, 0} = Tools.run("echo", ["quick"], timeout: 5_000)
    assert String.trim(output) == "quick"
  end

  test "a timeout kills a tool that wedges" do
    assert {:error, :timeout} = Tools.run("sh", ["-c", "sleep 5"], timeout: 100)
  end

  test "a timeout turns a tool that cannot be spawned into an error rather than a raise" do
    assert {:error, %ErlangError{original: :enoent}} =
             Tools.run("rail_no_such_binary_#{System.unique_integer([:positive])}", [], timeout: 5_000)
  end

  test "without a timeout an unspawnable tool still raises" do
    assert_raise ErlangError, fn ->
      Tools.run("rail_no_such_binary_#{System.unique_integer([:positive])}", [])
    end
  end

  test "an executable given as a path is run as given, and a bare name is found on PATH" do
    absolute = System.find_executable("echo")

    assert {output, 0} = Tools.run(absolute, ["absolute"])
    assert String.trim(output) == "absolute"

    assert {relative, 0} = Tools.run("./" <> Path.basename(absolute), [], cd: Path.dirname(absolute))
    assert String.trim(relative) == ""

    assert {found, 0} = Tools.run("echo", ["on path"])
    assert String.trim(found) == "on path"
  end
end
