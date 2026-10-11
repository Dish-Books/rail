defmodule RailWeb.Live.QuestionCard do
  @moduledoc """
  The card for a run's unsent round, docked in the composer's place, and the answer being typed into it.

  What is typed and which question is open live here, so working in the card redraws the card and never the stage beside it.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question

  # The page redraws around the card while the agent works, so what is in the box is only
  # dropped once the question it was for has left the round.
  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:selected_id, fn -> nil end)
      |> assign_new(:answer_text, fn -> "" end)

    %{questions: questions, selected_id: selected_id} = socket.assigns

    if Enum.any?(questions, &(&1.id == selected_id)),
      do: {:ok, socket},
      else: {:ok, open(socket, hd(questions))}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :question, selected_question(assigns))

    ~H"""
    <div
      id={@id}
      data-qa="question-card"
      hidden={@hidden}
      class="shrink-0 px-4 pt-3 pb-4 border-t border-slate-200 dark:border-slate-700 space-y-2.5"
    >
      <.answer_field
        question={@question}
        questions={@questions}
        suggestions={@suggestions}
        answer_text={@answer_text}
        target={@myself}
      />
    </div>
    """
  end

  @impl true
  def handle_event("select_question", %{"question_id" => question_id}, socket) do
    case Enum.find(socket.assigns.questions, &(&1.id == question_id)) do
      %Question{} = question -> {:noreply, open(socket, question)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("select_option", %{"option" => option}, socket) do
    {:noreply, assign(socket, :answer_text, option)}
  end

  def handle_event("answer_form_change", params, socket) do
    {:noreply, assign(socket, :answer_text, Map.get(params, "answer") || "")}
  end

  def handle_event("answer_question", params, socket) do
    answer = params |> Map.get("answer", socket.assigns.answer_text) |> to_string() |> String.trim()

    if answer == "" do
      {:noreply, socket}
    else
      question_id = question_id(socket, params)
      {:noreply, saved(socket, question_id, answer_one(socket, question_id, answer))}
    end
  end

  def handle_event("dismiss_question", params, socket) do
    question_id = question_id(socket, params)

    dismissed =
      with {:ok, question} <- round_question(socket, question_id) do
        Pipeline.dismiss_question(question)
      end

    {:noreply, saved(socket, question_id, dismissed)}
  end

  def handle_event("send_answers", _params, socket) do
    _sent = Pipeline.send_answers(socket.assigns.current_scope, socket.assigns.run)
    send(self(), :task_changed)
    {:noreply, socket}
  end

  def handle_event("dismiss_round", _params, socket) do
    _dismissed = Pipeline.dismiss_round(socket.assigns.run)
    send(self(), :task_changed)
    {:noreply, socket}
  end

  # The box opens on what the question already has: its saved answer, or while it is open the likely one.
  defp open(socket, %Question{} = question) do
    text =
      case question do
        %Question{status: :answered, answer: answer} -> answer
        %Question{status: :pending, id: id} -> get_in(socket.assigns.suggestions, [id, :answer]) || ""
        %Question{} -> ""
      end

    socket
    |> assign(:selected_id, question.id)
    |> assign(:answer_text, text)
  end

  # A chip picked from a card drawn before the round moved may name a question that has left it.
  defp selected_question(%{questions: questions, selected_id: selected_id}) do
    Enum.find(questions, hd(questions), &(&1.id == selected_id))
  end

  defp question_id(socket, params), do: Map.get(params, "question_id") || socket.assigns.selected_id

  # Only a question of this card's round, so a crafted id cannot reach another task's.
  defp round_question(socket, question_id) do
    if Enum.any?(socket.assigns.questions, &(&1.id == question_id)),
      do: Pipeline.get_question(question_id),
      else: {:error, :not_found}
  end

  defp answer_one(socket, question_id, answer) do
    with {:ok, question} <- round_question(socket, question_id) do
      Pipeline.answer_question(socket.assigns.current_scope, question, answer)
    end
  end

  # The saved question is folded in at once, so the card moves on to the next open
  # question without waiting for the page to read the round again.
  defp saved(socket, question_id, result) do
    questions =
      case result do
        {:ok, %Question{id: id} = question} ->
          Enum.map(socket.assigns.questions, &if(&1.id == id, do: question, else: &1))

        _not_saved ->
          socket.assigns.questions
      end

    send(self(), if(result == {:error, :already_sent}, do: :round_already_sent, else: :task_changed))

    socket = assign(socket, :questions, questions)

    next =
      Enum.find(questions, &(&1.status == :pending)) || selected_question(%{socket.assigns | selected_id: question_id})

    open(socket, next)
  end
end
