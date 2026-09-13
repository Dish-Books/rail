defmodule Rail.Issues.Utils.FormatLinearComment do
  @moduledoc """
  Reads a Linear comment, as the GraphQL API or a webhook sends it, into the
  attributes Rail keeps for it.
  """

  @doc """
  The comment attributes `node` describes, plus the Linear ids of what it points
  at: `:issue_external_id`, `:parent_external_id` and `:author_linear_id`. Those
  three are for the caller to resolve to Rail ids and drop.

  The API nests `issue`, `parent` and `user`; a webhook sends `issueId`,
  `parentId` and `userId` instead.
  """
  def format_linear_comment(%{"id" => id} = node) do
    user = node["user"] || %{}

    %{
      external_id: id,
      body: node["body"] || "",
      author_name: user["name"] || get_in(node, ["botActor", "name"]),
      author_avatar_url: user["avatarUrl"],
      inserted_at: timestamp(node["createdAt"]),
      updated_at: timestamp(node["updatedAt"] || node["createdAt"]),
      issue_external_id: get_in(node, ["issue", "id"]) || node["issueId"],
      parent_external_id: get_in(node, ["parent", "id"]) || node["parentId"],
      author_linear_id: user["id"] || node["userId"]
    }
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{microsecond: {usec, _precision}} = at, _offset} -> %{at | microsecond: {usec, 6}}
      {:error, _invalid} -> DateTime.utc_now()
    end
  end

  defp timestamp(_missing), do: DateTime.utc_now()
end
