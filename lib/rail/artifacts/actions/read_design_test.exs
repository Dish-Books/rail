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

    test "reads design directly from design directory", %{design_dir: design_dir} do
      scope = Scope.for_system()
      ArtifactHelpers.write_design_manifest(design_dir)

      assert {:ok, %{version: 1, directions: [_dir]}} =
               Artifacts.read_design(scope, design_dir, url_probe: fn _url -> true end)
    end

    test "reads design from parent scratch directory", %{dir: dir, design_dir: design_dir} do
      scope = Scope.user_scope()
      ArtifactHelpers.write_design_manifest(design_dir)

      assert {:ok, %{version: 1}} =
               Artifacts.read_design(scope, dir, url_probe: fn _url -> true end)
    end

    test "reads design using task struct and scratch option", %{dir: dir, design_dir: design_dir} do
      scope = Scope.user_scope()
      ArtifactHelpers.write_design_manifest(design_dir)

      assert {:ok, %{version: 1}} =
               Artifacts.read_design(scope, %{id: "tsk_dsg_1"},
                 scratch_dir: dir,
                 url_probe: fn _url -> true end
               )
    end

    test "reads design using task id string and scratch option", %{dir: dir, design_dir: design_dir} do
      scope = Scope.user_scope()
      ArtifactHelpers.write_design_manifest(design_dir)

      assert {:ok, %{version: 1}} =
               Artifacts.read_design(scope, "tsk_dsg_1",
                 scratch_dir: dir,
                 url_probe: fn _url -> true end
               )
    end

    test "returns validation failure when manifest is invalid", %{design_dir: design_dir} do
      scope = Scope.for_system()
      File.write!(Path.join(design_dir, "manifest.json"), "{bad_json")

      assert {:error, msg} = Artifacts.read_design(scope, design_dir)
      assert msg =~ "Failed to parse design manifest"
    end

    test "returns error when manifest does not exist" do
      scope = Scope.for_system()
      assert {:error, msg} = Artifacts.read_design(scope, "/nonexistent/design/dir")
      assert msg =~ "No design manifest found"
    end
  end
end
