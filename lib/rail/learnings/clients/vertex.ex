defmodule Rail.Learnings.Clients.Vertex do
  @moduledoc """
  Embeds text with Vertex AI's `gemini-embedding-001`, on the token and project
  Goth holds, at the global endpoint.
  """

  @model "gemini-embedding-001"
  @dimensions 3072

  @doc "The model every stored embedding is for."
  def model, do: @model

  @doc """
  Embeds `text` for `task_type`, such as `RETRIEVAL_DOCUMENT` or `RETRIEVAL_QUERY`.
  Returns `{:ok, values}`, or an error without a request when Goth is off.
  """
  def embed(text, task_type) when is_binary(text) and is_binary(task_type) do
    if Rail.goth_enabled?(), do: request(text, task_type), else: {:error, :goth_disabled}
  end

  defp request(text, task_type) do
    with {:ok, %{token: token}} <- Goth.fetch(Rail.Goth),
         {:ok, project_id} <- Goth.Config.get(:project_id) do
      [
        base_url: "https://aiplatform.googleapis.com/v1",
        url: "/projects/#{project_id}/locations/global/publishers/google/models/#{@model}:predict",
        auth: {:bearer, token},
        json: %{
          instances: [%{content: text, task_type: task_type}],
          parameters: %{outputDimensionality: @dimensions}
        }
      ]
      |> Req.post(Keyword.get(Application.get_env(:rail, :vertex, []), :req_options, []))
      |> case do
        {:ok, %{status: 200, body: %{"predictions" => [%{"embeddings" => %{"values" => [_first | _rest] = values}}]}}} ->
          {:ok, values}

        {:ok, %{status: status, body: body}} ->
          {:error, {:vertex_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
