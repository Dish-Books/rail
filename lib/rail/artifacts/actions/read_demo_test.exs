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

    test "reads demo directly from demo directory", %{demo_dir: demo_dir} do
      scope = Scope.for_system()
      ArtifactHelpers.write_demo_manifest(demo_dir)

      assert {:ok, %{outcome: "recorded", segments: [_seg]}} = Artifacts.read_demo(scope, demo_dir)
    end

    test "reads demo from parent scratch directory", %{dir: dir, demo_dir: demo_dir} do
      scope = Scope.user_scope()
      ArtifactHelpers.write_demo_manifest(demo_dir)

      assert {:ok, %{outcome: "recorded"}} = Artifacts.read_demo(scope, dir)
    end

    test "reads demo using task struct and scratch option", %{dir: dir, demo_dir: demo_dir} do
      scope = Scope.user_scope()
      ArtifactHelpers.write_demo_manifest(demo_dir)

      assert {:ok, %{outcome: "recorded"}} = Artifacts.read_demo(scope, %{id: "tsk_1"}, scratch_dir: dir)
    end

    test "reads demo using task id string and scratch option", %{dir: dir, demo_dir: demo_dir} do
      scope = Scope.user_scope()
      ArtifactHelpers.write_demo_manifest(demo_dir)

      assert {:ok, %{outcome: "recorded"}} = Artifacts.read_demo(scope, "tsk_1", scratch_dir: dir)
    end

    test "reads demo from .rail/demo directory and task struct with worktree_path", %{dir: dir} do
      scope = Scope.for_system()
      rail_demo_dir = Path.join([dir, ".rail", "demo"])
      File.mkdir_p!(rail_demo_dir)
      ArtifactHelpers.write_demo_manifest(rail_demo_dir)

      assert {:ok, %{outcome: "recorded"}} = Artifacts.read_demo(scope, dir)
      assert {:ok, %{outcome: "recorded"}} = Artifacts.read_demo(scope, %{id: "tsk_2", worktree_path: dir})
    end

    test "returns validation failure when manifest is invalid", %{demo_dir: demo_dir} do
      scope = Scope.for_system()
      File.write!(Path.join(demo_dir, "manifest.json"), "{bad_json")

      assert {:error, msg} = Artifacts.read_demo(scope, demo_dir)
      assert msg =~ "Failed to parse demo manifest"
    end

    test "returns error when manifest does not exist" do
      scope = Scope.for_system()
      assert {:error, msg} = Artifacts.read_demo(scope, "/nonexistent/demo/dir")
      assert msg =~ "Demo manifest not found"
    end

    test "rejects non-scope caller", %{demo_dir: demo_dir} do
      assert {:error, :not_authorized} = Artifacts.read_demo(:not_a_scope, demo_dir, [])
    end
  end
end
