defmodule Rail.Domain.StageVerdictTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.StageVerdict

  test "changeset/2 validates required verdict" do
    valid_changeset = StageVerdict.changeset(%StageVerdict{}, %{verdict: :passed, explanation: "All good"})
    assert valid_changeset.valid?

    invalid_changeset = StageVerdict.changeset(%StageVerdict{}, %{verdict: nil})
    refute invalid_changeset.valid?
    assert "can't be blank" in errors_on(invalid_changeset).verdict
  end

  test "defaults to unclear" do
    assert %StageVerdict{verdict: :unclear, status: :unclear, explanation: nil} = %StageVerdict{}
  end
end
