defmodule Rail.Tools.BrowserRecorder do
  @moduledoc """
  Films what a task's browser is looking at, for as long as the task is being
  demonstrated.

  `Rail.Tools.BrowserSession` already broadcasts every frame Chrome encodes on
  `"browser:<task id>"`, and Chrome only encodes one when the page actually
  changes. So a recording is a subscriber and nothing more: the session does not
  know it is being filmed, a QA pass costs exactly what it costs today, and the
  frames arrive already compressed.

  What is written is a directory of JPEGs and a line per frame saying when it
  arrived. Not a video: encoding is something ffmpeg does once, at the end, from
  a recording that is finished. Writing a line per frame as it lands is what
  makes a run that dies half way still leave a demo - every frame up to the crash
  is on disk and the timings with them.

  The clock starts at the first frame rather than at `start_link/1`. A browser
  takes a second or two to launch and paint, and a video that opens on two
  seconds of nothing is a video a person skips past.

  Each recording replaces the last. A task that is demonstrated twice has one
  demo, and it is the one that was just recorded.
  """
  use GenServer, restart: :temporary

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.RecorderRegistry

  @doc """
  Starts the recording for `task` and returns its process.
  """
  def start_link(opts) do
    task = Keyword.fetch!(opts, :task)

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {RecorderRegistry, task.id}})
  end

  @doc """
  How long this recording has been running, in milliseconds.

  Zero before the first frame, which is also where the video starts, so a
  caption stamped before anything has painted lands on the opening frame rather
  than off the front of the film.
  """
  def elapsed_ms(pid), do: GenServer.call(pid, :elapsed_ms)

  @doc """
  Stops recording and returns the directory holding the frames and their timings.
  """
  def finish(pid) do
    ref = Process.monitor(pid)
    directory = GenServer.call(pid, :finish)

    # The reply lands before the exit, and a take started in between would find this one still running.
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> directory
    end
  end

  @impl true
  def init(opts) do
    %Task{} = task = Keyword.fetch!(opts, :task)
    directory = Keyword.fetch!(opts, :directory)

    File.rm_rf(directory)
    File.mkdir_p!(Path.join(directory, "frames"))

    Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task.id}")

    {:ok, %{directory: directory, started_at: nil, count: 0}}
  end

  @impl true
  def handle_call(:elapsed_ms, _from, state), do: {:reply, elapsed(state), state}

  def handle_call(:finish, _from, state), do: {:stop, :normal, state.directory, state}

  @impl true
  def handle_info({:browser_frame, _task_id, data}, state) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:noreply, write(state, bytes)}
      # coveralls-ignore-next-line (Chrome sending a frame that is not base64)
      :error -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The frame is written first and its line second, so the index never names a
  # file that is not there. A reader that finds a frame with no line has one
  # frame too many, which is the harmless way round.
  defp write(state, bytes) do
    state = %{state | started_at: state.started_at || System.monotonic_time(:millisecond)}
    at_ms = elapsed(state)
    file = "#{String.pad_leading(to_string(state.count), 6, "0")}.jpg"

    File.write!(Path.join([state.directory, "frames", file]), bytes)

    File.write!(
      Path.join(state.directory, "frames.jsonl"),
      [Jason.encode_to_iodata!(%{file: file, at_ms: at_ms}), "\n"],
      [:append]
    )

    %{state | count: state.count + 1}
  end

  defp elapsed(%{started_at: nil}), do: 0
  defp elapsed(%{started_at: started_at}), do: System.monotonic_time(:millisecond) - started_at
end
