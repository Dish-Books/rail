defmodule Rail.Artifacts.Actions.ReadQaReportTest do
  use ExUnit.Case, async: true

  alias Rail.Artifacts
  alias Rail.Scope
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_read_qa"

  setup do
    dir = Path.join(@tmp_base, "task_#{System.unique_integer([:positive])}")
    qa_dir = Path.join(dir, "qa")
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, qa_dir: qa_dir}
  end

  describe "read_qa_report/3" do
    test "rejects unauthorized scope", %{dir: dir} do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.read_qa_report(scope, dir)
    end

    test "reads QA report directly from qa directory", %{qa_dir: qa_dir} do
      scope = Scope.for_system()
      ArtifactHelpers.write_qa_manifest(qa_dir)

      assert {:ok, %{commit: "abc1234", rows: [_row]}} = Artifacts.read_qa_report(scope, qa_dir)
    end

    test "reads QA report from parent scratch directory", %{dir: dir, qa_dir: qa_dir} do
      scope = Scope.user_scope()
      ArtifactHelpers.write_qa_manifest(qa_dir)

      assert {:ok, %{commit: "abc1234"}} = Artifacts.read_qa_report(scope, dir)
    end

    test "reads QA report using task struct and scratch option", %{dir: dir, qa_dir: qa_dir} do
      scope = Scope.user_scope()
      ArtifactHelpers.write_qa_manifest(qa_dir)

      assert {:ok, %{commit: "abc1234"}} = Artifacts.read_qa_report(scope, %{id: "tsk_qa_1"}, scratch_dir: dir)
    end

    test "reads QA report using task id string and scratch option", %{dir: dir, qa_dir: qa_dir} do
      scope = Scope.user_scope()
      ArtifactHelpers.write_qa_manifest(qa_dir)

      assert {:ok, %{commit: "abc1234"}} = Artifacts.read_qa_report(scope, "tsk_qa_1", scratch_dir: dir)
    end

    test "reads QA report directly from manifest in root directory", %{dir: dir} do
      scope = Scope.for_system()
      ArtifactHelpers.write_qa_manifest(dir)

      assert {:ok, %{commit: "abc1234"}} = Artifacts.read_qa_report(scope, dir)
    end

    test "reads QA report from worktree .axis/qa directory", %{dir: dir} do
      scope = Scope.for_system()
      axis_qa = Path.join([dir, ".axis", "qa"])
      File.mkdir_p!(axis_qa)
      ArtifactHelpers.write_qa_manifest(axis_qa)

      # Via worktree path string
      assert {:ok, %{commit: "abc1234"}} = Artifacts.read_qa_report(scope, dir)

      # Via Task struct with worktree_path
      task = %Rail.Pipeline.Schemas.Task{id: "tsk_wt_qa", worktree_path: dir}
      assert {:ok, %{commit: "abc1234"}} = Artifacts.read_qa_report(scope, task)
    end

    test "returns validation failure when manifest is invalid", %{qa_dir: qa_dir} do
      scope = Scope.for_system()
      File.write!(Path.join(qa_dir, "manifest.json"), "{bad_json")

      assert {:error, msg} = Artifacts.read_qa_report(scope, qa_dir)
      assert msg =~ "Failed to parse QA manifest"
    end

    test "returns error when manifest does not exist" do
      scope = Scope.for_system()
      assert {:error, msg} = Artifacts.read_qa_report(scope, "/nonexistent/qa/dir")
      assert msg =~ "QA manifest not found"
    end
  end
end
