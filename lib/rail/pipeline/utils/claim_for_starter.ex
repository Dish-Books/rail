defmodule Rail.Pipeline.Utils.ClaimForStarter do
  @moduledoc """
  Makes whoever starts an issue's task its owner, in the transaction that records the task.
  """

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Scope

  @doc """
  Claims `issue` for the scope's user and returns `:ok` whatever the claim says, since a refusal never stops a start.
  A scope with no user, such as a workflow's, claims nothing.
  """
  def claim_for_starter(%Scope{user: nil}, %Issue{}), do: :ok

  def claim_for_starter(%Scope{} = scope, %Issue{} = issue) do
    case Issues.claim_issue(scope, issue) do
      {:ok, %Issue{}} -> :ok
      # Owned already, or the tracker cannot name this person: the task page still offers Claim.
      {:error, _refused} -> :ok
    end
  end
end
