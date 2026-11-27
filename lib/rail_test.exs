defmodule RailTest do
  use ExUnit.Case, async: true

  # A sandbox mounts this folder read-only, so it must be the one mise itself installs into.
  test "the toolchain a sandbox reads is where mise keeps its data" do
    assert Rail.mise_data_dir() == System.get_env("MISE_DATA_DIR")
  end
end
