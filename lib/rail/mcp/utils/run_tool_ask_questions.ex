defmodule Rail.Mcp.Utils.RunToolAskQuestions do
  @moduledoc """
  Files a lead's round of questions on its run, for the human to answer once its turn ends.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Files the questions in `arguments` on the run of the calling process and says how many were asked, or refuses
  naming every bad entry by its number, with nothing filed.
  """
  def run_tool_ask_questions(%Task{}, %{"questions" => [_first | _rest] = questions}, opts) do
    {:ok, run} = Pipeline.get_run(Keyword.fetch!(opts, :os_process).run_id)

    entries =
      for entry <- questions,
          do: if(is_map(entry), do: %{"prompt" => entry["prompt"], "options" => entry["options"]}, else: entry)

    case Pipeline.ask_questions(run, entries) do
      {:ok, %{asked: asked, already: already}} -> {:ok, said(length(asked), length(already))}
      {:error, invalid} -> {:refused, refused(invalid)}
    end
  end

  def run_tool_ask_questions(%Task{}, %{"questions" => []}, _opts) do
    {:refused, "Refused, nothing asked. questions is empty: list every question you could not close."}
  end

  def run_tool_ask_questions(%Task{}, _arguments, _opts) do
    {:refused,
     "Refused, nothing asked. questions is required: a list of objects, each with a prompt and optional options."}
  end

  defp said(0, already), do: "Nothing new to ask: #{count(already)} already asked this turn."

  defp said(asked, 0), do: "Asked #{count(asked)}. The human sees the round when your turn ends."

  defp said(asked, already),
    do: "Asked #{count(asked)}, and #{already} already asked. The human sees the round when your turn ends."

  defp count(1), do: "1 question"
  defp count(n), do: "#{n} questions"

  defp refused(invalid) do
    named =
      Enum.map_join(invalid, " ", fn {number, changeset} ->
        problems = Enum.map_join(Enum.reverse(changeset.errors), ", ", &problem/1)
        "Question #{number}: #{problems}."
      end)

    "Refused, nothing asked. " <> named <> " Fix them and ask the whole list again."
  end

  defp problem({:question, {message, _opts}}), do: "it #{message}"
  defp problem({:prompt, {_message, validation: :required}}), do: "prompt is required"
  defp problem({:prompt, {_message, _opts}}), do: "prompt must be text"
  defp problem({:options, {_message, _opts}}), do: "options must be a list of text"
end
