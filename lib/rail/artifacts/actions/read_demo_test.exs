defmodule Rail.Artifacts.Actions.ReadDemoTest do
  use ExUnit.Case, async: true

  alias Rail.Artifacts
  alias Rail.Scope
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_read_demo"

  setup do
    dir = Path.join(@tmp_base, "task_#{System.unique_integer([:positive])}")
    demo_dir = Path.join(dir, "demo")
    File.mkdir_p!(demo_dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, demo_dir: demo_dir}
  end

  describe "read_demo/3" do
    test "rejects unauthorized scope", %{dir: dir} do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.read_demo(scope, dir)
    end

    test "reads the manifest out of the scratch directory's demo/", %{dir: dir, demo_dir: demo_dir} do
      scope = Scope.for_system()
      ArtifactHelpers.write_demo_manifest(demo_dir)

      assert {:ok, %{outcome: "recorded", segments: [_segment]}} = Artifacts.read_demo(scope, dir)
    end

    # The scratch directory is the only place a recording is looked for: one written
    # into the worktree instead is a demo Rail never saw.
    test "ignores a manifest left in the worktree's .rail/demo", %{dir: dir} do
      scope = Scope.for_system()
      rail_demo = Path.join([dir, ".rail", "demo"])
      File.mkdir_p!(rail_demo)
      ArtifactHelpers.write_demo_manifest(rail_demo)

      assert {:error, msg} = Artifacts.read_demo(scope, dir)
      assert msg =~ "Demo manifest not found"
    end

    test "returns validation failure when manifest is invalid", %{dir: dir, demo_dir: demo_dir} do
      scope = Scope.for_system()
      File.write!(Path.join(demo_dir, "manifest.json"), "{bad_json")

      assert {:error, msg} = Artifacts.read_demo(scope, dir)
      assert msg =~ "Failed to parse demo manifest"
    end

    test "returns error when manifest does not exist" do
      scope = Scope.for_system()
      assert {:error, msg} = Artifacts.read_demo(scope, "/nonexistent/scratch")
      assert msg =~ "Demo manifest not found"
    end

    test "rejects non-scope caller", %{dir: dir} do
      assert {:error, :not_authorized} = Artifacts.read_demo(:not_a_scope, dir, [])
    end
  end
end
