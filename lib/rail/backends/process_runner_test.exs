defmodule Rail.Backends.ProcessRunnerTest do
  use Rail.DataCase, async: true

  alias Rail.Backends.ProcessRunner

  test "run/3 executes command and returns output" do
    assert {:ok, stdout, 0} = ProcessRunner.run("echo", ["hello_world"])
    assert String.contains?(stdout, "hello_world")
  end

  test "run/3 times out when execution exceeds timeout" do
    assert {:error, :timeout} = ProcessRunner.run("sleep", ["2"], timeout: 50)
  end

  test "run/3 returns error when command raises" do
    assert {:error, %ErlangError{}} = ProcessRunner.run("/path/to/definitely/invalid/runner_binary", [])
  end

  test "normalize_result/1 normalizes diverse runner output representations" do
    assert {:ok, "out", 0} = ProcessRunner.normalize_result({:ok, "out", 0})
    assert {:ok, "out", 0} = ProcessRunner.normalize_result({"out", 0})
    assert {:ok, "out", 0} = ProcessRunner.normalize_result({:ok, %{stdout: "out", exit_code: 0}})
    assert {:error, :timeout} = ProcessRunner.normalize_result({:error, :timeout})
  end
end
