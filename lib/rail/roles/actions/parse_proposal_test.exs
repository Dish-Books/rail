defmodule Rail.Roles.Actions.ParseProposalTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.FileDiff
  alias Rail.Roles
  alias Rail.Roles.RoleInstructionProposal

  test "parses proposal and builds diff against current prompt" do
    current_prompt = "Line 1\nLine 2\nLine 3"

    output = """
    I analyzed the past runs and noticed we need more test rigor.

    <<<INSTRUCTIONS>>>
    Line 1
    Line 2 revised
    Line 3
    Line 4 new
    <<<END INSTRUCTIONS>>>

    These modifications will prevent regression.
    """

    assert {:ok, %RoleInstructionProposal{} = proposal} =
             Roles.parse_proposal(
               output,
               "rol_123",
               "claude-3-7-sonnet",
               current_prompt,
               [],
               %{"input_tokens" => 100}
             )

    assert %RoleInstructionProposal{
             role_id: "rol_123",
             model_id: "claude-3-7-sonnet",
             current: ^current_prompt,
             proposed: "Line 1\nLine 2 revised\nLine 3\nLine 4 new",
             rationale:
               "I analyzed the past runs and noticed we need more test rigor.\n\nThese modifications will prevent regression.",
             diff: %FileDiff{status: :modified, path: "instructions.md", additions: 2, deletions: 1},
             usage: %{"input_tokens" => 100}
           } = proposal
  end

  test "returns no_marker_block when start marker is missing" do
    output = "Here are the instructions: Line 1 <<<END INSTRUCTIONS>>>"

    assert {:error, :no_marker_block} =
             Roles.parse_proposal(output, "rol_1", "claude", "current", [])
  end

  test "returns no_marker_block when end marker is missing" do
    output = "<<<INSTRUCTIONS>>>\nNew instructions without end."

    assert {:error, :no_marker_block} =
             Roles.parse_proposal(output, "rol_1", "claude", "current", [])
  end

  test "returns no_marker_block when proposed instructions are blank" do
    output = "Rationale <<<INSTRUCTIONS>>>   \n  \t  <<<END INSTRUCTIONS>>> After"

    assert {:error, :no_marker_block} =
             Roles.parse_proposal(output, "rol_1", "claude", "current", [])
  end

  test "returns no_marker_block on invalid argument types" do
    assert {:error, :no_marker_block} =
             Roles.parse_proposal(nil, "rol_1", "claude", "current", [])
  end
end
