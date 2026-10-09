defmodule Rail.Tools.Schemas.ToolchainInstallTest do
  use Rail.DataCase, async: true

  alias Rail.Tools.Schemas.ToolchainInstall

  test "changeset/3 takes the project from its caller and needs a command and a commit", %{project: project} do
    assert %Ecto.Changeset{valid?: true} =
             changeset =
             ToolchainInstall.changeset(%ToolchainInstall{}, %{command: "mise install", head_sha: "abc123"}, project.id)

    assert get_field(changeset, :project_id) == project.id
    assert get_field(changeset, :status) == :queued

    assert %{command: [_blank], head_sha: [_missing]} =
             errors_on(ToolchainInstall.changeset(%ToolchainInstall{}, %{command: ""}, project.id))
  end

  test "checkout_path/1 is inside the project's clone", %{project: project} do
    assert ToolchainInstall.checkout_path(project) == Path.join(project.clone_path, ".worktrees/toolchain")
  end
end
