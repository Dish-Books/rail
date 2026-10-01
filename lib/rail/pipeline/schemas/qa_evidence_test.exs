defmodule Rail.Pipeline.Schemas.QaEvidenceTest do
  use ExUnit.Case, async: true

  alias Rail.Pipeline.Schemas.QaEvidence

  test "a line logged at error level, or one that begins an exception, is an error line" do
    for line <- [
          "[error] #PID<0.4817.0> running LedgerWeb.Endpoint terminated",
          "2026-10-01 12:00:01 ERROR export failed",
          "ts=2026-10-01 level=error msg=\"export failed\"",
          "    ** (FunctionClauseError) no function clause matching in TaxRate.percent/1",
          "** (exit) an exception was raised:"
        ] do
      assert QaEvidence.error_line?(line), line
    end
  end

  test "a line that only talks about errors is not one" do
    for line <- [
          "[info] Sent 200 in 41ms",
          "assert %{name: [\"can't be blank\"]} = errors_on(changeset)",
          "No ERRORS found",
          "the error count is 0",
          ""
        ] do
      refute QaEvidence.error_line?(line), line
    end
  end

  # `qa_shot` joins the check to the caption with a `~`, and hands that name
  # back for the finding to cite.
  test "a screenshot qa_shot filed is a path, and one climbing out is not" do
    assert QaEvidence.changeset(%QaEvidence{}, %{name: "n", kind: :screenshot, path: "evidence/totals~the-entry.jpg"}).valid?

    refute QaEvidence.changeset(%QaEvidence{}, %{name: "n", kind: :screenshot, path: "~/secrets.txt"}).valid?
    refute QaEvidence.changeset(%QaEvidence{}, %{name: "n", kind: :screenshot, path: "evidence/../../x"}).valid?
  end
end
