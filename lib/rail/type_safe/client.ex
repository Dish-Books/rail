defmodule Rail.TypeSafe.Client do
  @moduledoc """
  Puts one state and several typed questions to TypeSafe, and returns its answers.

  Every question sees the same state and is answered independently, so asking
  four costs one round trip. That is what makes driving a browser this way
  affordable: the operation to perform and the target for each operation it could
  be are all asked at once, and only the target belonging to the chosen operation
  is read.

  An answer is a choice out of an offered set. The one thing not trusted on the
  way back is that the choice is one of them: it becomes an element to click, so
  a choice Rail never offered is no answer rather than a bad one. What TypeSafe
  says about its own confidence is carried through as it arrived.
  """

  @endpoint "https://api.typesafe.ai/v1/systemone"
  @transient [408, 429, 500, 502, 503, 504, 529]

  @doc """
  Answers `questions` against `state`.

  Returns `{:ok, answers}` keyed the way the questions were, where each answer is
  `%{choice: choice, confidence: float}`. A `:type_safe_unavailable` is worth
  another attempt; nothing else is.
  """
  def ask(state, questions, opts) when map_size(questions) > 0 do
    body = %{model: model(), state: state, questions: questions}

    case Req.post(request(opts), json: body) do
      {:ok, %Req.Response{status: status, body: body}} when status in @transient ->
        {:error, {:type_safe_unavailable, status, detail(body)}}

      {:ok, %Req.Response{status: 200, body: %{"answers" => answers}}} when is_map(answers) ->
        validate(answers, questions)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:type_safe_unusable_response, status, detail(body)}}

      {:error, exception} ->
        {:error, {:type_safe_unavailable, :transport, Exception.message(exception)}}
    end
  end

  def ask(_state, _questions, _opts), do: {:ok, %{}}

  # An answer is only usable if it names something that was offered, because that
  # is what becomes a click.
  defp validate(answers, questions) do
    Enum.reduce_while(questions, {:ok, %{}}, fn {name, question}, {:ok, acc} ->
      case answer(answers[to_string(name)], choices(question)) do
        {:ok, answer} -> {:cont, {:ok, Map.put(acc, name, answer)}}
        {:error, reason} -> {:halt, {:error, {:type_safe_unusable_answer, name, reason}}}
      end
    end)
  end

  defp choices(%{criteria: criteria}), do: criteria |> Map.new() |> Map.keys() |> Enum.map(&to_string/1)

  defp answer(%{"choice" => choice} = answer, offered) do
    if choice in offered do
      {:ok, %{choice: choice, confidence: answer["confidence"]}}
    else
      {:error, :choice_not_offered}
    end
  end

  defp answer(_missing, _offered), do: {:error, :no_answer}

  defp request(opts) do
    [url: @endpoint, auth: {:bearer, api_key()}, receive_timeout: 25_000]
    |> Req.new()
    |> Req.merge(Keyword.get(config(), :req_options, []))
    |> Req.merge(Keyword.get(opts, :req_options, []))
  end

  defp detail(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp detail(body), do: body |> inspect() |> String.slice(0, 500)

  defp api_key, do: Keyword.get(config(), :api_key, "")
  defp model, do: Keyword.get(config(), :model, "jev-latest")
  defp config, do: Application.get_env(:rail, :type_safe, [])
end
