defmodule Rail.Artifacts.Actions.ReadDesignTest do
  use ExUnit.Case, async: true

  alias Rail.Artifacts
  alias Rail.Scope
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_read_design"

  setup do
    dir = Path.join(@tmp_base, "task_#{System.unique_integer([:positive])}")
    design_dir = Path.join(dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, design_dir: design_dir}
  end

  describe "read_design/3" do
    test "rejects unauthorized scope", %{dir: dir} do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.read_design(scope, dir)
    end

    test "reads the manifest out of the scratch directory's design/", %{dir: dir, design_dir: design_dir} do
      scope = Scope.for_system()
      ArtifactHelpers.write_design_manifest(design_dir)

      assert {:ok, %{version: 1, directions: [_direction]}} =
               Artifacts.read_design(scope, dir, url_probe: fn _url -> true end)
    end

    # The scratch directory is the only place a manifest is looked for: one written
    # into the worktree instead is a design Rail never saw.
    test "ignores a manifest left in the worktree's .rail/design", %{dir: dir} do
      scope = Scope.for_system()
      rail_design = Path.join([dir, ".rail", "design"])
      File.mkdir_p!(rail_design)
      ArtifactHelpers.write_design_manifest(rail_design)

      assert {:error, msg} = Artifacts.read_design(scope, dir)
      assert msg =~ "No design manifest found"
    end

    test "returns validation failure when manifest is invalid", %{dir: dir, design_dir: design_dir} do
      scope = Scope.for_system()
      File.write!(Path.join(design_dir, "manifest.json"), "{bad_json")

      assert {:error, msg} = Artifacts.read_design(scope, dir)
      assert msg =~ "Failed to parse design manifest"
    end

    test "returns error when manifest does not exist" do
      scope = Scope.for_system()
      assert {:error, msg} = Artifacts.read_design(scope, "/nonexistent/scratch")
      assert msg =~ "No design manifest found"
    end
  end
end
