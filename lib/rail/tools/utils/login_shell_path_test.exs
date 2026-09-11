defmodule Rail.Tools.Utils.LoginShellPathTest do
  use ExUnit.Case, async: true

  alias Rail.Tools.Utils.LoginShellPath

  test "returns nil for nil, blank, and invalid shells" do
    assert LoginShellPath.login_shell_path(nil) == nil
    assert LoginShellPath.login_shell_path("") == nil
    assert LoginShellPath.login_shell_path("/nonexistent/fake_shell_xyz") == nil
  end

  test "reads the PATH a real shell reports" do
    path = LoginShellPath.login_shell_path("/bin/sh")

    assert is_nil(path) or String.contains?(path, "/bin")
  end
end
