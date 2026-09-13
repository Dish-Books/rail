defmodule Rail.Pipeline.Schemas.StageVerdictTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.StageVerdict

  test "changeset/2 validates required verdict" do
    valid_changeset = StageVerdict.changeset(%StageVerdict{}, %{verdict: :passed, explanation: "All good"})
    assert valid_changeset.valid?

    invalid_changeset = StageVerdict.changeset(%StageVerdict{}, %{verdict: nil})
    refute invalid_changeset.valid?
    assert "can't be blank" in errors_on(invalid_changeset).verdict
  end

  test "leaves verdict and status unclear until a run says otherwise" do
    applied = %StageVerdict{} |> StageVerdict.changeset(%{}) |> Ecto.Changeset.apply_changes()

    assert %StageVerdict{verdict: :unclear, status: :unclear, explanation: nil} = applied
  end
end
