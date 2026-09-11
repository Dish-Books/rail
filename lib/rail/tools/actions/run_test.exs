defmodule Rail.Tools.Actions.RunTest do
  use ExUnit.Case, async: true

  alias Rail.Tools

  test "executes command with resolved path and merged env" do
    assert {output, 0} = Tools.run("echo", ["hello tools"])
    assert String.trim(output) == "hello tools"

    assert {output_env, 0} =
             Tools.run("sh", ["-c", "echo $CUSTOM_VAR"], env: %{"CUSTOM_VAR" => "rail_test"})

    assert String.trim(output_env) == "rail_test"
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
end
