defmodule RailWeb.Components.TriageVerdictTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.TriageVerdict

  test "draws every verdict under its label, and each kind" do
    for {kind, verdict, label} <- [
          {:bug, :confirmed, "Confirmed"},
          {:bug, :not_reproduced, "Could not reproduce"},
          {:bug, :already_fixed, "Already fixed"},
          {:feature_request, :built, "Built"},
          {:feature_request, :partly_built, "Partly built"},
          {:feature_request, :not_built, "Not built"}
        ] do
      assert render_component(&TriageVerdict.triage_verdict/1, kind: kind, verdict: verdict) =~ label
    end

    assert render_component(&TriageVerdict.triage_verdict/1, kind: :bug) =~ "Bug"
    assert render_component(&TriageVerdict.triage_verdict/1, kind: :feature_request) =~ "Feature request"
  end
end
